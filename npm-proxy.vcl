#
# This VCL is for use with Varnish 3.x
#
# You must compile and install libvmod-rewrite, available from:
# https://github.com/aivarsk/libvmod-rewrite
#
# If you alter the number of public backends, you will need to update:
# - vcl_recv to incorporate the backend in the restart logic.
# - vcl_fetch and vcl_error to reflect the number of public backends in use.
#

### BACKENDS
backend couchdb {
  .host = "127.0.0.1";
  .port = "5984";
  .probe = {
    .url = "/";
    .interval = 10s;
    .timeout = 25s;
    .window = 5;
    .threshold = 3;
  }
}

backend public_registry_npmjs_org {
  .host = "registry.npmjs.org";
  .port = "80";
  .connect_timeout = 5s;
}

backend public_registry_npmjs_eu {
  .host = "registry.npmjs.eu";
  .port = "80";
  .connect_timeout = 5s;
}

backend public_registry_strongloop {
  .host = "npm.strongloop.com";
  .port = "80";
  .connect_timeout = 5s;
}

backend alwaysdown {
  .host = "127.0.0.1";
  .port = "1";
  .connect_timeout = 0.1s;
  .probe = {
    .interval = 1s;
    .window = 1;
    .threshold = 1;
    .initial = 0;
  }
}

### REQUEST PROCESSING LOGIC

sub vcl_recv {
  if (req.restarts == 0) {
    # Try our private registry first. Non-GET and Replication requests are piped through.
    set req.backend = couchdb;

    if (req.url ~ "^/registry/_design/app/_rewrite") {
      set req.url = regsub(req.url, "^/registry/_design/app/_rewrite", "");
    }

    if (req.request != "GET" || req.url ~ "/_changes\?") {
      return (pipe);
    }
  } else {
    # Only allow GET requests to be sent to other backends.
    if (req.request == "GET") {
      if (req.restarts == 1) {
        # On first request, unset the authorization details.
        unset req.http.authorization;

        # Try official NPM registry first, since this is authoritative.
        set req.http.host = "registry.npmjs.org";
        set req.backend = public_registry_npmjs_org;
      } else if (req.restarts == 2) {
        set req.http.host = "registry.npmjs.eu";
        set req.backend = public_registry_npmjs_eu;
      } else if (req.restarts == 3) {
        set req.http.host = "npm.strongloop.com";
        set req.backend = public_registry_strongloop;
      }
    }
  }

  if (req.http.magicmarker == "true") {
    unset req.http.magicmarker;
    set req.backend = alwaysdown;
  }

  if (! req.backend.healthy) {
    set req.grace = 24h;
  } else {
    set req.grace = 1m;
  }
}

sub vcl_fetch {
  # Don't retry 404 if we've exhausted backends we can try.
  if (req.restarts < 3 && beresp.status == 404) {
    return (restart);
  }

  # If the backend returns a 5xx code, restart and trigger saint mode.
  if (beresp.status >= 500 && beresp.status < 600) {
    set beresp.saintmode = 10s;
    return(restart);
  }

  if (req.url ~ "^/-/all") {
    set beresp.ttl = 0s;
    return (deliver);
  }

  if (req.restarts > 0 && req.request == "GET" && beresp.status == 200) {
    if (beresp.http.content-type ~ "application/octet-stream") {
      set beresp.ttl = 1w;
    }
    set beresp.grace = 1w;
    return (deliver);
  }


  if (req.http.Cookie || beresp.http.Cache-Control ~ "(private|no-store|no-cache)" || beresp.status >= 400) {
    set beresp.ttl = 0s;
  }

  if (beresp.ttl <= 0s) {
    return (deliver);
  }
}

sub vcl_pipe {
  set bereq.http.connection = "close";
}

# TARBALL REWRITES
import rewrite;
sub vcl_deliver {
  if (resp.http.content-type ~ "application/json") {
    rewrite.rewrite_re({"tarball":"http(s)?://[^/]+/"},{"tarball":"http://npm.example.com/"}); # CHANGE THIS ADDRESS TO THE NAME OF YOUR PROXY
  }
}

sub vcl_error {
  if (req.request == "GET" && obj.status >= 500 && obj.status < 600) {
    if (req.restarts < 3) {
      return (restart);
    } else {
      set req.http.magicmarker = "true";
      return (restart);
    }
  }
}
