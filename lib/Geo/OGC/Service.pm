=pod

=head1 NAME

Geo::OGC::Service - Perl extension for geospatial web services

=head1 SYNOPSIS

In a service.psgi file write something like this

  use strict;
  use warnings;
  use Geo::OGC::Service;
  use Geo::OGC::Service::WFS;
  my $app = Geo::OGC::Service->psgi_app(
    config => '/var/www/etc/test.conf',
    services => {
        test => 'Geo::OGC::Service::Test',
    }
    );
  $app;

The bones of a service class are

  package Geo::OGC::Service::Test;
  sub process_request {
    my ($self, $responder) = @_;
    my $writer = $responder->([200, [ 'Content-Type' => 'text/plain',
                                      'Content-Encoding' => 'UTF-8' ]]);
    $writer->write("I'm ok!");
    $writer->close;
  }

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
configuration file, for example

/var/www/etc/test.conf

(make sure this file is not served by apache)

The configuration must be in JSON format. I.e., something like

  {
    "CORS": "*",
    "Content-Type": "text/xml",
    "version": "1.1.0",
    "TARGET_NAMESPACE": "http://ogr.maptools.org/"
  }

The keys and structure of this file depend on the type of the service
you are setting up. "CORS" is the only one that is recognized by this
module. "CORS" is either a string denoting the allowed origin or a
hash of "Allow-Origin", "Allow-Methods", "Allow-Headers", and
"Max-Age".

=head2 EXPORT

None by default.

=head2 METHODS

=cut

package Geo::OGC::Service;

use 5.022000;
use Modern::Perl;
use Encode qw(decode encode);
use Plack::Request;
use JSON;
use XML::LibXML;
use Clone 'clone';
use XML::LibXML::PrettyPrint;

binmode STDERR, ":utf8"; 

our $VERSION = '0.03';

=pod

=head3 psgi_app

This is the psgi app boot method. You need to call it in the psgi file
as a class method with a named parameter hash reference. The
parameters are

  configuration, services

configuration is a path to a file.

services is a reference to a hash of service names associated with
names of classes, which will process those service requests.

=cut

sub psgi_app {
    my ($class, $parameters) = @_;
    return sub {
        my $env = shift;
        if (! $env->{'psgi.streaming'}) { # after Lyra-Core/lib/Lyra/Trait/Async/PsgiApp.pm
            return [ 500, ["Content-Type" => "text/plain"], "Internal Server Error (Server Implementation Mismatch)" ];
        }
        return sub {
            my $responder = shift;
            respond($responder, $env, $parameters->{config}, $parameters->{services});
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
configuration file. Above are the default ones.

In the default case this method constructs a new service object and
calls its process_request method with PSGI style $responder object as
a parameter.

This subroutine may fail due to an error in the configuration file, 
while interpreting the request, or while processing the request.

=cut

sub respond {
    my ($responder, $env, $config, $services) = @_;
    if (open(my $fh, '<', $config)) {
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
        print STDERR "Can't open file '$config': $!\n";
        undef $config;
    }
    unless ($config) {
        error($responder, { exceptionCode => 'ResourceNotFound',
                            ExceptionText => 'Configuration error.' } );
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
        my $service;
        eval {
            $service = service($responder, $env, $config, $services);
        };
        if ($@) {
            print STDERR "$@";
            error($responder, { exceptionCode => 'ResourceNotFound',
                                ExceptionText => "Internal error while interpreting the request." } );
        } elsif ($service) {
            eval {
                $service->process_request($responder);
            };
            if ($@) {
                print STDERR "$@";
                error($responder, { exceptionCode => 'ResourceNotFound',
                                    ExceptionText => "Internal error while processing the request." } );
            }
        }
    }
}

=pod

=head3 service

This subroutine does a preliminary interpretation of the request and
converts it into a service object. The contents of the configuration
is merged into the object.

The returned service object contains

  config => a clone of the configuration for this service
  env => many values from the PSGI environment

and may contain

  posted => XML::LibXML DOM document element of the posted data
  filter => XML::LibXML DOM document element of the filter
  parameters => hash of rquest parameters obtained from Plack::Request

Note: all keys in request parameters are converted to lower case in
parameters.

This subroutine may fail due to a request for an unknown service.

=cut

sub service {
    my ($responder, $env, $config, $services) = @_;

    my $request = Plack::Request->new($env);
    my $parameters = $request->parameters;
    
    my %names;
    for my $key (sort keys %$parameters) {
        $names{lc($key)} = $key;
    }

    my $self = { config => clone($config) };
    for my $key (qw/SCRIPT_NAME PATH_INFO SERVER_NAME SERVER_PORT SERVER_PROTOCOL CONTENT_LENGTH CONTENT_TYPE
                    psgi.version psgi.url_scheme psgi.multithread psgi.multiprocess psgi.run_once psgi.nonblocking psgi.streaming/) {
        $self->{env}{$key} = $env->{$key};
    };
    for my $key (keys %$env) {
        $self->{env}{$key} = $env->{$key} if $key =~ /^HTTP_/ || $key =~ /^REQUEST_/;
    };

    my $post = $names{postdata} // $names{'xforms:model'};
    $post = $post ? $parameters->{$post} : encode($request->content_encoding // 'UTF-8', $request->content);

    if ($post) {
        my $parser = XML::LibXML->new(no_blanks => 1);
        my $dom;
        eval {
            $dom = $parser->load_xml(string => $post);
        };
        if ($@) {
            error($responder, { exceptionCode => 'ResourceNotFound',
                                ExceptionText => "Error in posted XML:\n$@" } );
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
                    error($responder, { exceptionCode => 'ResourceNotFound',
                                        ExceptionText => "Error in XML filter:\n$@" } );
                    return;
                }
                $self->{filter} = $dom->documentElement();
            } else {
                $self->{parameters}{$key} = $parameters->{$names{$key}};
            }
        }
    }

    # service may also be an attribute in the top element of posted XML
    my $service_from_posted = sub {
        my $node = shift;
        return undef unless $node;
        return $node->getAttribute('service');
    };

    my $service = $self->{parameters}{service} // $service_from_posted->($self->{posted}) // ''; 

    if (exists $services->{$service}) {
        return bless $self, $services->{$service};
    }

    error($responder, { exceptionCode => 'InvalidParameterValue',
                        locator => 'service',
                        ExceptionText => "'$service' is not a known service to this server" } );
    return undef;
}

sub error {
    my ($responder, $msg) = @_;
    my $writer = Geo::OGC::Service::XMLWriter::Caching->new('text/xml');
    $writer->open_element('ExceptionReport', { version => "1.0" });
    my $attributes = { exceptionCode => $msg->{exceptionCode} };
    my $content;
    $content = [ ExceptionText => $msg->{ExceptionText} ] if exists $msg->{ExceptionText};
    if ($msg->{exceptionCode} eq 'MissingParameterValue') {
        $attributes->{locator} = $msg->{locator};
    }
    $writer->element('Exception', $attributes, $content);
    $writer->close_element;
    $writer->stream($responder);
}

=pod

=head1 XMLWriter

A helper class for writing XML.

=head2 SYNOPSIS

  my $writer = Geo::OGC::Service::XMLWriter::Caching->new();
  $writer->open_element(
        'wfs:WFS_Capabilities', 
        { 'xmlns:gml' => "http://www.opengis.net/gml" });
  $writer->element('ows:ServiceProvider',
                     [['ows:ProviderName'],
                      ['ows:ProviderSite', {'xlink:type'=>"simple", 'xlink:href'=>""}],
                      ['ows:ServiceContact']]);
  $writer->close_element;
  $writer->stream($responder);

or 

  use Capture::Tiny ':all';
  my $writer = Geo::OGC::Service::XMLWriter::Streaming->new($responder);
  for (@a_very_very_long_list) {
    my $stdout = capture_stdout {
      say something;
    };
    $writer->write($stdout);
  }

=head2 DESCRIPTION

The classes Geo::OGC::Service::XMLWriter (abstract),
Geo::OGC::Service::XMLWriter::Streaming (concrete), and
Geo::OGC::Service::XMLWriter::Caching (concrete) are provided as a
convenience for writing XML to the client.

The element method has the syntax

  $writer->xml_element($tag[, $attributes][, $content])

$attributes is a reference to a hash

$content is a reference to a list of xml elements (tag...)

=cut

package Geo::OGC::Service::XMLWriter;
use Modern::Perl;

sub element {
    my $self = shift;
    my $element = shift;
    my $attributes;
    my $content;
    for my $x (@_) {
        $attributes = $x, next if ref($x) eq 'HASH';
        $content = $x;
    }
    if (defined $content && $content eq '/>') {
        $self->write("</$element>");
        return;
    }
    $self->write("<$element");
    if ($attributes) {
        for my $a (keys %$attributes) {
            $self->write(" $a=\"$attributes->{$a}\"");
        }
    }
    unless (defined $content) {
        $self->write(" />");
    } else {
        $self->write(">");
        if (ref $content) {
            if (ref $content->[0]) {
                for my $e (@$content) {
                    $self->element(@$e);
                }
            } else {
                $self->element(@$content);
            }
            $self->write("</$element>");
        } elsif ($content eq '>') {
        } else {
            $self->write("$content</$element>");
        }
    }
}

sub open_element {
    my $self = shift;
    my $element = shift;
    my $attributes;
    for my $x (@_) {
        $attributes = $x, next if ref($x) eq 'HASH';
    }
    $self->write("<$element");
    if ($attributes) {
        for my $a (keys %$attributes) {
            $self->write(" $a=\"$attributes->{$a}\"");
        }
    }
    $self->write(">");
    $self->{open_element} = [] unless $self->{open_element};
    push @{$self->{open_element}}, $element;
}

sub close_element {
    my $self = shift;
    my $element = pop @{$self->{open_element}};
    $self->write("</$element>");
}

package Geo::OGC::Service::XMLWriter::Streaming;
use Modern::Perl;

our @ISA = qw(Geo::OGC::Service::XMLWriter Plack::Util::Prototype); # can't use parent since Plack is not yet

sub new {
    my ($class, $responder, $content_type) = @_;
    $content_type //= 'text/xml';
    my $self = $responder->([200, [ 'Content-Type' => $content_type,
                                    'Content-Encoding' => 'UTF-8' ]]);
    return bless $self, $class;
}

sub prolog {
    my $self = shift;
    $self->write('<?xml version="1.0" encoding="UTF-8"?>');
}

sub DESTROY {
    my $self = shift;
    $self->close;
}

package Geo::OGC::Service::XMLWriter::Caching;
use Modern::Perl;

our @ISA = qw(Geo::OGC::Service::XMLWriter);

sub new {
    my ($class, $content_type) = @_;
    $content_type //= 'text/xml';
    my $self = {
        cache => [],
        content_type => $content_type
    };
    $self->{cache} = [];
    return bless $self, $class;
}

sub write {
    my $self = shift;
    my $line = shift;
    push @{$self->{cache}}, $line;
}

sub stream {
    my $self = shift;
    my $responder = shift;
    my $debug = shift;
    my $writer = $responder->([200, [ 'Content-Type' => $self->{content_type},
                                      'Content-Encoding' => 'UTF-8' ]]);
    $writer->write('<?xml version="1.0" encoding="UTF-8"?>');
    my $xml = '';
    for my $line (@{$self->{cache}}) {
        $writer->write($line);
        $xml .= $line;
    }
    $writer->close;
    if ($debug) {
        my $parser = XML::LibXML->new(no_blanks => 1);
        my $pp = XML::LibXML::PrettyPrint->new(indent_string => "  ");
        my $dom = $parser->load_xml(string => $xml);
        $pp->pretty_print($dom);
        say STDERR $dom->toString;
    }
}

1;
__END__

=head1 SEE ALSO

Discuss this module on the Geo-perl email list.

L<https://list.hut.fi/mailman/listinfo/geo-perl>

For PSGI/Plack see 

L<http://plackperl.org/>

=head1 REPOSITORY

L<https://github.com/ajolma/Geo-OGC-Service>

=head1 AUTHOR

Ari Jolma, E<lt>ari.jolma at gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015 by Ari Jolma

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.22.0 or,
at your option, any later version of Perl 5 you may have available.

=cut
