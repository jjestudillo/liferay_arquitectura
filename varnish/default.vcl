vcl 4.0;

import std;
import dynamic;

# Default backend definition. Set this to point to your content server.
backend default {
    .host = "127.0.0.1";
    .port = "8080";
}

acl purge {
	"localhost";
	"127.0.0.1";
	"::1";
}

sub vcl_init {
  new elb_dir = dynamic.director(
    port = "80",
    ttl = 1m
  );
}

sub vcl_recv {
	# Happens before we check if we have this in cache already.
	#
	# Typically you clean up the request here, removing cookies you don't need,
	# rewriting the request, etc.
	
	if (req.method != "GET" &&
		req.method != "HEAD" &&
		req.method != "PUT" &&
		req.method != "POST" &&
		req.method != "TRACE" &&
		req.method != "OPTIONS" &&
		req.method != "PATCH" &&
		req.method != "DELETE" &&
		req.method != "PURGE") {
		/* Non-RFC2616 or CONNECT which is weird. */
		/* Why send the packet upstream, while the visitor is using a non-valid HTTP method? */
		return(synth(500, "Non-valid HTTP method!"));
	}
	
	# Purge cache
	if (req.method == "PURGE") {
		if (!client.ip ~ purge) {
			return(synth(405, "Not allowed."));
		}

		if (req.http.X-Purge-Regex) {
			ban("req.http.X-Cache-Type == " + req.http.X-Purge-Regex);
			return(synth(200, "Ban added"));
		} else {
			return (purge);
		}
	}
	
	# Varnish health check
	if ((req.url ~ "^/status") && (req.http.host == "LOCAL_IPV4")) {
		return (synth(800, "OK"));
	}
	
	# Backend reference
	set req.backend_hint = elb_dir.backend("LIFERAY_ELB");
	
	# Bypass for static resources from varnish (error page, maintenance, ...)
	if (req.url ~ "^/resources") {
		# Bypass for all the local resources a local error page
		return(synth(810, "Bypass request"));
	}
	
	if (req.http.Upgrade ~ "(?i)websocket") {
		return (pipe);
	}
	
	
	if (req.http.Cookie ~ "(__utm|_ga|_gat|utmctr|utmcmd|utmccn)") {
		set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
		set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
		set req.http.Cookie = regsuball(req.http.Cookie, "_gat=[^;]+(; )?", "");
		set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
		set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
		set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");
	}
	
	if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=") {
		set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
		set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
		set req.url = regsub(req.url, "\?&", "?");
		set req.url = regsub(req.url, "\?$", "");
	}
	
	set req.url = std.querysort(req.url);
	
	if (req.http.X-Forwarded-For) {
		set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
	} else {
		set req.http.X-Forwarded-For = client.ip;
	}
	
	if (req.method != "GET" && req.method != "HEAD") {
		set req.http.X-Cacheable = "NO: User interaction";
		return(pass);
	}
	
	if (std.tolower(req.url) ~ "^[^?]*\.(7z|avi|bmp|bz2|css|csv|doc|docx|vsd|eot|flac|flv|gif|gz|ico|jpeg|jpg|js|less|mka|mkv|mov|mp3|mp4|m4a|mpeg|mpg|wmv|odt|otf|ogg|ogm|opus|pdf|png|ppt|pptx|rar|rtf|svg|svgz|swf|tar|tbz|tgz|ttf|txt|txz|wav|webm|webp|woff|woff2|xls|xlsx|xml|xz|zip|tiff|tif|json)(\?.*)?$") {
		set req.http.X-Cacheable = "YES: Static resource";
		set req.http.X-Cache-Type = "RESOURCE";
		return(hash);
	}
	
	if (req.url ~ "/(documents|o|combo|image)/" || req.url ~ "(available_languages)") {
		set req.http.X-Cacheable = "YES: Static resource";
		set req.http.X-Cache-Type = "RESOURCE";
		return(hash);
	}
	
	//TODO Completar con los casos particulares
	
	set req.http.X-Cacheable = "NO: Default";
	set req.http.X-Cache-Type = "PAGE";
	return(pass);
}

sub vcl_backend_response {
	# Happens after we have read the response headers from the backend.
	#
	# Here you clean the response headers, removing silly Set-Cookie headers
	# and other mistakes your backend does.
	
	if (beresp.http.Content-Encoding ~ "gzip" ) {
		if (beresp.http.Content-Length == "0") {
			unset beresp.http.Content-Encoding;
		}
	}
	
	if (beresp.http.X-Powered-By) {
		unset beresp.http.X-Powered-By;
	}
	
	if (beresp.http.Liferay-Portal) {
		unset beresp.http.Liferay-Portal;
	}
	
	if (beresp.status == 200 || beresp.status == 304) {
		if (std.tolower(bereq.url) ~ "^[^?]*\.(7z|avi|bmp|bz2|css|csv|doc|docx|vsd|eot|flac|flv|gif|gz|ico|jpeg|jpg|js|less|mka|mkv|mov|mp3|mp4|m4a|mpeg|mpg|wmv|odt|otf|ogg|ogm|opus|pdf|png|ppt|pptx|rar|rtf|svg|svgz|swf|tar|tbz|tgz|ttf|txt|txz|wav|webm|webp|woff|woff2|xls|xlsx|xml|xz|zip|tiff|tif|json)(\?.*)?$") {
			unset beresp.http.Set-Cookie;
			unset beresp.http.Cookie;
			set beresp.http.Cache-Control = "max-age=315360000, public";
			set beresp.http.Expires = "" + (now + std.duration("10y", 60s));
			set beresp.ttl = 10y;
			return(deliver);
		}
		
		if (beresp.http.Set-Cookie) {
			set beresp.http.Cache-Control = "no-cache";
			unset beresp.http.Expires;
			unset beresp.http.Last-Modified;
			unset beresp.http.ETag;
			unset beresp.http.Pragma;
			set beresp.ttl = 0s;
			return (deliver);
		}
	
		if (bereq.http.X-Cacheable ~ "^NO") {
			set beresp.http.Cache-Control = "no-cache";
			unset beresp.http.Expires;
			unset beresp.http.Last-Modified;
			unset beresp.http.ETag;
			unset beresp.http.Pragma;
			set beresp.ttl = 0s;
			return(deliver);
		}
		
		unset beresp.http.Set-Cookie;
		unset beresp.http.Cookie;
		
		# set beresp.http.Cache-Control = "max-age=86400, public";
		# set beresp.http.Expires = "" + (now + std.duration("1d", 60s));
		# unset beresp.http.ETag;
		# set beresp.ttl = 1d;
		# set beresp.grace = 1d;
	} else if (beresp.status == 404) {
		# Cache 404 responses
		unset beresp.http.Set-Cookie;
		unset beresp.http.Cookie;
		set beresp.http.Cache-Control = "max-age=1200, public";
		set beresp.http.Expires = "" + (now + std.duration("20m", 1m));
		set beresp.ttl = 20m;
		set beresp.grace = 20m;
	}
	
	return(deliver);	
}

sub vcl_backend_error {
	if (beresp.status == 500 || beresp.status == 502 || beresp.status == 503 || beresp.status == 504) {
		set beresp.http.Content-Type = "text/html; charset=utf-8";
		synthetic(std.fileread("/etc/varnish/resources/error/error.html"));
		return(deliver);
	}
}

sub vcl_hash {
	if (req.http.X-Cacheable ~ "^YES") {
		if (req.method != "GET" && req.method != "HEAD" && req.http.Cookie ~ "JSESSIONID") {
			hash_data(req.http.host + "-" + req.http.X-Cache-Type + "-" + req.url + "-" + regsub(req.http.Cookie, ".*JSESSIONID=([^;]+);.*", "\1" ));
			set req.http.X-Calc-hash = req.http.host + "-" + req.http.X-Cache-Type + "-" + req.url + "-" + regsub(req.http.Cookie, ".*JSESSIONID=([^;]+);.*", "\1" );
			return(lookup);
		}

		hash_data(req.http.host + "-" + req.http.X-Cache-Type + "-" + req.url);
		set req.http.X-Calc-hash = req.http.host + "-" + req.http.X-Cache-Type + "-" + req.url;
	}
}

sub vcl_deliver {
	# Happens when we have all the pieces we need, and are about to send the
	# response to the client.
	#
	# You can do accounting or modifying the final object here.

	if (obj.hits > 0) {
		set resp.http.X-Cache = "HIT";
	} else {
		set resp.http.X-Cache = "MISS";
	}
	set resp.http.X-Cache-Hits = obj.hits;

	unset resp.http.X-Varnish;
	unset resp.http.Via;
}

sub vcl_synth {
	if (resp.status == 800) {
		set resp.status = 200;
		set resp.http.Content-Type = "text/plain; charset=utf-8";
		synthetic(resp.reason);
		return (deliver);
	} else if (resp.status == 810) {
		# Serve a local resources for common error page
		set resp.status = 200;
		synthetic(std.fileread("/etc/varnish" + req.url));
		return(deliver);
	} else if (resp.status == 500 || resp.status == 502 || resp.status == 503 || resp.status == 504 || resp.status == 405) {
		# Serve a local error page
		set resp.http.Content-Type = "text/html; charset=utf-8";
		set resp.http.Cache-Control = "no-cache";
		unset resp.http.Expires;
		unset resp.http.Last-Modified;
		unset resp.http.ETag;
		unset resp.http.Pragma;
		synthetic(std.fileread("/etc/varnish/resources/error/error.html"));
		return(deliver);
	}
}

sub vcl_pipe {
	if (req.http.upgrade) {
		set bereq.http.upgrade = req.http.upgrade;
	}

	return (pipe);
}