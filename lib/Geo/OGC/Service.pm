=pod

=head1 NAME

Geo::OGC::Service - Perl extension for geospatial web services

=head1 SYNOPSIS

In a service.psgi file write something like this

  use strict;
  use warnings;
  use Geo::OGC::Service;
  my $app = Geo::OGC::Service->psgi_app(
    '/var/www/etc/dispatch', 
    'TestApp',
    {
        'WFS' => 'Geo::OGC::Service::WFS',
    }
    );
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

Setting up a geospatial web service configuration requires a
configuration table file, for example

/var/www/etc/dispatch 

(make sure this file is not served by apache)

The dispatch file should consist of lines with two items separated by
a tab. The first item should be the string that is the parameter to
psgi_app above (MyService in this case). The second item should be a
path to a file which contains the configuration for the service. The
configuration must be in JSON format. I.e., something like

  {
    "CORS": "*",
    "MIME": "text/xml",
    "version": "1.1.0",
    "TARGET_NAMESPACE": "http://ogr.maptools.org/"
  }

The keys and structure of this file depend on the type of the service
you are setting up. "CORS" and "debug" are the only ones that are
recognized by this module. "CORS" is either a string denoting the
allowed origin or a hash of "Allow-Origin", "Allow-Methods",
"Allow-Headers", and "Max-Age".

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
use XML::LibXML;
use Clone 'clone';

our $VERSION = '0.01';

=pod

=head3 psgi_app

This is the psgi app boot method. You need to call it in the psgi
file as a class method. The parameters are

  configuration_table, service_name, services

configuration_table is a path to a file of pairs of service names and
service configuration.

service_name is the name of this service and a key in the
configuration_table.

services is a reference to a hash of OGC service names associated with
names of classes, which should process those service requests.

=cut

sub psgi_app {
    my ($class, $configuration_table, $service_name, $services) = @_;
    return sub {
        my $env = shift;
        if (! $env->{'psgi.streaming'}) { # after Lyra-Core/lib/Lyra/Trait/Async/PsgiApp.pm
            return [ 500, ["Content-Type" => "text/plain"], "Internal Server Error (Server Implementation Mismatch)" ];
        }
        return sub {
            my $responder = shift;
            respond($responder, $env, $configuration_table, $service_name, $services);
        }
    }
}

=pod

=head3 respond

This subroutine is called for each request from the Internet. The call
is responded during the execution of the subroutine. First, the
configuration file is read and decoded. If the request is "OPTIONS"
the call is responded with the following headers

  Content-Type = text/plain
  Access-Control-Allow-Origin = ""
  Access-Control-Allow-Methods = "GET,POST"
  Access-Control-Allow-Headers = "origin,x-requested-with,content-type"
  Access-Control-Max-Age = 60*60*24

The values of Access-Control-* keys can be set in the
configuration file. The above values are the default ones.

In the default case this method constructs a new service object and
calls its process_request method with PSGI style $responder object as
a parameter.

This subroutine may fail due to an error in the configuration file, 
while interpreting the request, and while processing the request.

=cut

sub respond {
    my ($responder, $env, $configuration_table, $service_name, $services) = @_;
    my $config;
    if (open(my $fh, '<', $configuration_table)) {
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
        my $request = Plack::Request->new($env);
        my $service;
        eval {
            $service = service($responder, $request, $config, $services);
        };
        if ($@) {
            print STDERR "$@";
            error($responder, "Error in interpreting the request.");
        } elsif ($service) {
            eval {
                $service->process_request($responder);
            };
            if ($@) {
                print STDERR "$@";
                error($responder, "Error in processing the request.");
            }
        }
    }
}

=pod

=head3 service

This subroutine does a preliminary interpretation of the request and
converts it into a service object. The contents of the configuration
is merged into the object.

The returned service object may contain the following information

  config => a clone of the configuration for this service
  posted => XML::LibXML DOM document element of the posted data
  filter => XML::LibXML DOM document element of the filter
  parameters => hash of rquest parameters obtained from Plack::Request

This subroutine may fail due to a request for an unknown service.

=cut

sub service {
    my ($responder, $request, $config, $services) = @_;

    my $parameters = $request->parameters;
    
    my %names;
    for my $key (sort keys %$parameters) {
        $names{lc($key)} = $key;
        print STDERR "request kvp: $key => $parameters->{$key}\n" if $config->{debug} > 2;
    }

    my $self = { config => clone($config) };
    
    my $post = $names{postdata} // $names{'xforms:model'};

    if ($post) {
        my $parser = XML::LibXML->new(no_blanks => 1);
        my $dom;
        eval {
            $dom = $parser->load_xml(string => $parameters->{$post});
        };
        if ($@) {
            error($responder, "Error in posted XML:\n$@");
            return;
        }
        $self->{posted} = $dom->documentElement();
    } else {
        for my $key (keys %names) {
            if ($key eq 'filter' and $parameters->{$names{filter}} =~ /^</) {
                my $filter = $parameters->{$names{filter}};
                my $s = '<ogc:Filter xmlns:ogc="http://www.opengis.net/ogc">';
                $filter =~ s/<ogc:Filter>/$s/;
                my $parser = XML::LibXML->new(no_blanks => 1);
                my $dom;
                eval {
                    $dom = $parser->load_xml(string => $filter);
                };
                if ($@) {
                    error($responder, "Error in XML filter:\n$@");
                    return;
                }
                $self->{filter} = $dom->documentElement();
            } else {
                $self->{parameters}{$key} = $parameters->{$names{$key}};
            }
        }
    }

    my $service = $self->{parameters}{service} // '';
    if (exists $services->{$service}) {
        return bless $self, $services->{$service};
    }

    error($responder, "Unknown service requested: '$service'.");
}

sub error {
    my ($responder, $msg) = @_;
    my $writer = $responder->([500, [ 'Content-Type' => 'text/plain',
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
