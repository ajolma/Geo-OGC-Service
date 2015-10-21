=pod

=head1 NAME

Geo::OGC::Service - Perl extension for geospatial web services

=head1 SYNOPSIS

Put this into your service.psgi file:

  use strict;
  use warnings;
  use Geo::OGC::Service;
  my $app = OGC::Service->psgi_app('MyService');
  $app;

=head1 DESCRIPTION

This module provides psgi_app and respond methods for booting a web
service.

=head2 SERVICE CONFIGURATION

Setting up a PSGI service consists typically of three things: 

1) write a service.psgi file (see above) and put it somewhere like

/var/www/service/service.psgi 

2) Set up starman service and add to its init-file line something like

  exec starman --daemonize --error-log /var/log/starman/log --l localhost:5000 /var/www/service/service.psgi

3) Add a proxy service to your apache configuration

  <Location /TestApp>
    ProxyPass http://localhost:5000/ 
    ProxyPassReverse http://localhost:5000/
  </Location>

Setting up a geospatial web service configuration requires a file

/var/www/etc/dispatch 

(make sure this file is not served by apache)

The dispatch file should consist of lines each with two items,
separated by a tabulator. The first item should be the string that is
the parameter to psgi_app above (MyService in this case). The second
item should be a path to a file which contains the configuration for
the service. The configuration must be in JSON format. I.e., something
like

  {
    "CORS": "*",
    "MIME": "text/xml",
    "version": "1.1.0",
    "TARGET_NAMESPACE": "http://ogr.maptools.org/"
  }

The keys etc. of this file depends on the type of the service you are
setting up. "CORS" and "debug" are the only ones that are recognized
by this module. "CORS" is either a string denoting the allowed origin
or a hash of "Allow-Origin", "Allow-Methods", "Allow-Headers", and
"Max-Age".

=head2 EXPORT

None by default.

=head2 METHODS

=cut

package Geo::OGC::Service;

use 5.022000;
use strict;
use warnings;
use Plack::Request;
use JSON;
use Geo::OGC::Request;

our $VERSION = '0.01';

=pod

=head3 psgi_app

This is the psgi app boot method. It is called by Plack.

=cut

sub psgi_app {
    my ($class, $service_name) = @_;
    return sub {
        my $env = shift;
        if (! $env->{'psgi.streaming'}) { # after Lyra-Core/lib/Lyra/Trait/Async/PsgiApp.pm
            return [ 500, ["Content-Type" => "text/plain"], "Internal Server Error (Server Implementation Mismatch)" ];
        }
        return sub {
            my $responder = shift;
            respond($responder, $env, $service_name);
        }
    }
}

=pod

=head3 respond

This is the respond method that is called for each request from the
Internet by Plack. This method reads and decodes the configuration
file or fails with a "Configuration error" message. If the request is
"OPTIONS" this method responds with the following headers

  Content-Type = text/plain
  Access-Control-Allow-Origin = ""
  Access-Control-Allow-Methods = "GET,POST"
  Access-Control-Allow-Headers = "origin,x-requested-with,content-type"
  Access-Control-Max-Age = 60*60*24

As said above, the values of Access-Control-* keys can be set in the
configuration. The above values are the default ones.

In the default case this method constructs a new OGC::Request object
and calls its process_request method.

=cut

sub respond {
    my ($responder, $env, $service_name) = @_;
    my $req = Plack::Request->new($env);
    my $config;
    if (open(my $fh, '<', '/var/www/etc/dispatch')) {
        while (<$fh>) {
            chomp;
            my @l = split /\t/;
            $config = $l[1] if $l[0] and $l[0] eq $service_name;
        }
        close $fh;
        if ($config && open(my $fh, '<', $config)) {
            my @json = <$fh>;
            close $fh;
            eval {
                $config = decode_json "@json";
            };
            unless ($@) {
                $config->{CORS} = $ENV{'REMOTE_ADDR'} unless $config->{CORS};
                $config->{debug} = 0 unless defined $config->{debug};
            } else {
                print STDERR "$@";
                undef $config;
            }
        } else {
            undef $config;
        }
    }
    unless ($config) {
        error($responder, 'Configuration error.');
    } elsif ($env->{REQUEST_METHOD} eq 'OPTIONS') {
        my %cors = ( 
            'Content-Type' => 'text/plain',
            'Allow-Origin' => "",
            'Allow-Methods' => "GET,POST",
            'Allow-Headers' => "origin,x-requested-with,content-type",
            'Max-Age' => 60*60*24 );
        if (ref $config->{CORS} eq 'HASH') {
            for my $key (keys %cors) {
                $cors{$key} = $config->{CORS}{$key} // $cors{$key};
            }
        } else {
            $cors{Origin} = $config->{CORS};
        }
        for my $key (keys %cors) {
            next if $key =~ /^Content/;
            $cors{'Access-Control-'.$key} = $cors{$key};
            delete $cors{$key};
        }
        $responder->([200, [%cors]]);
    } else {
        my $ogc_req;
        eval {
            $ogc_req = Geo::OGC::Request->new($responder, $req, $config);
        };
        if ($@) {
            print STDERR "$@";
            error($responder, "Error in interpreting the request.");
        } elsif ($ogc_req) {
            eval {
                $ogc_req->process_request($responder);
            };
            if ($@) {
                print STDERR "$@";
                error($responder, "Error in processing the request.");
            }
        }
    }
}

sub error {
    my ($responder, $msg) = @_;
    my $writer = $responder->([200, [ 'Content-Type' => 'text/plain',
                                      'Content-Encoding' => 'UTF-8' ]]);
    $writer->write($msg);
    $writer->close;
}

1;
__END__

=head1 SEE ALSO

Discuss this module on the Geo-perl email list.

L<https://list.hut.fi/mailman/listinfo/geo-perl>

For PSGI/Plack see 

L<http://plackperl.org/>

=head1 AUTHOR

Ari Jolma, E<lt>ari.jolma at gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015 by Ari Jolma

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.22.0 or,
at your option, any later version of Perl 5 you may have available.

=cut
