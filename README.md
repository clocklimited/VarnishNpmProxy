# Sample VCL for Constructing an NPM Proxy with Varnish


## Requirements
* Varnish 3.x
* Compile and install libvmod-rewrite
  * https://github.com/aivarsk/libvmod-rewrite

## Suggested Varnish Options

Use file storage (-s file) and allow a few GB for tarball storage.

## Limitations

Any backends specified must resolve to a single IP address. Varnish 3 expects a single
backend to be defined per IP:Port combination used, so backends with multiple A records
cannot be used directly.

