=pod

=head1 NAME

Geo::OGC::Service - Perl extension for geospatial web services

=head1 SYNOPSIS

In a service.psgi file write something like this

  use strict;
  use warnings;
  use Plack::Builder;
  use Geo::OGC::Service;
  use Geo::OGC::Service::XXX;
  my $server = Geo::OGC::Service->new({
      config => '/var/www/etc/test.conf',
      services => {
          XXX => 'Geo::OGC::Service::XXX',
      }
  });
  builder {
      mount "/XXX" => $server->to_app;
      mount "/" => $default_app;
  };

The bones of a service class are

  package Geo::OGC::Service::XXX;
  sub process_request {
    my ($self, $responder) = @_;
    my $writer = $responder->([200, [ 'Content-Type' => 'text/plain',
                                      'Content-Encoding' => 'UTF-8' ]]);
    $writer->write("I'm ok!");
    $writer->close;
  }

Geo::OGC::Service::WFS exists in the CPAN and Geo::OGC::Service::WMTS
will be there real soon now.

=head1 DESCRIPTION

This module provides a to_app method for booting a web service.
Geo::OGC::Service is a subclass of Plack::Component.

=head2 SERVICE CONFIGURATION

Setting up a PSGI service consists typically of three things: 

1) write a service.psgi file (see above) and put it somewhere like

   /var/www/service/service.psgi 

2) Set up starman service and add to its init-file line something like

   exec starman --daemonize --error-log /var/log/starman/log --l localhost:5000 /var/www/service/service.psgi

3) Add a proxy service to your apache configuration

   <Location /Service>
     ProxyPass http://localhost:5000
     ProxyPassReverse http://localhost:5000
   </Location>

Setting up a geospatial web service through this module requires a
configuration file, for example

/var/www/etc/service.conf

(make sure this file is not served by apache)

The configuration must be in JSON format. I.e., something like

  {
    "CORS": "*",
    "Content-Type": "text/xml; charset=utf-8",
    "version": "1.1.0",
    "TARGET_NAMESPACE": "http://ogr.maptools.org/"
  }

The keys and structure of this file depend on the type of the
service(s) you are setting up. "CORS" is the only one that is
recognized by this module. "CORS" is either a string denoting the
allowed origin or a hash of "Allow-Origin", "Allow-Methods",
"Allow-Headers", and "Max-Age".

=head2 EXPORT

None by default.

=head2 METHODS

=cut

package Geo::OGC::Service;

use 5.010000; # say // and //=
use Carp;
use Modern::Perl;
use Encode qw(decode encode);
use Plack::Request;
use Plack::Builder;
use JSON;
use XML::LibXML;
use Clone 'clone';
use XML::LibXML::PrettyPrint;

use parent qw/Plack::Component/;

binmode STDERR, ":utf8"; 

our $VERSION = '0.08';

=pod

=head3 new

This creates a new Geo::OGC::Service app. You need to call it in the
psgi file as a class method with a named parameter hash reference. The
parameters are

  config, services

config is required and it is a path to a file or a reference to an
anonymous hash containing the configuration for the services.

services is a reference to a hash of service names associated with
names of classes, which will process service requests. The key of the
hash is the requested service.

=cut

sub new {
    my ($class, $parameters) = @_;
    my $self = Plack::Component->new($parameters);
    if (not ref $self->{config}) {
        open my $fh, '<', $self->{config} or croak "Can't open file '$self->{config}': $!\n";
        my @json = <$fh>;
        close $fh;
        $self->{config} = decode_json "@json";
        $self->{config}{debug} = 0 unless defined $self->{config}{debug};
    }
    croak "A configuration file is needed." unless $self->{config};
    croak "No services are defined." unless $self->{services};
    return bless $self, $class;
}

=pod

=head3 call

This method is called internally by the method to_app of
Plack::Component. The method fails unless this module
is running in a psgi.streaming environment. Otherwise,
it returns a subroutine, which calls the respond method.

=cut

sub call {
    my ($self, $env) = @_;
    if (! $env->{'psgi.streaming'}) { # after Lyra-Core/lib/Lyra/Trait/Async/PsgiApp.pm
        return [ 500, ["Content-Type" => "text/plain"], ["Internal Server Error (Server Implementation Mismatch)"] ];
    }
    return sub {
        my $responder = shift;
        $self->respond($responder, $env);
    }
}

=pod

=head3 respond

This method is called for each request from the Internet. The call is
responded during the execution of the subroutine. If the request is
"OPTIONS" the call is responded with the following headers

  Content-Type = text/plain
  Access-Control-Allow-Origin = ""
  Access-Control-Allow-Methods = "GET,POST"
  Access-Control-Allow-Headers = "origin,x-requested-with,content-type"
  Access-Control-Max-Age = 60*60*24

The values of Access-Control-* keys can be set in the
configuration file. Above are the default ones.

In the default case this method constructs a new service object using
the method 'service' and calls its process_request method with PSGI
style $responder object as a parameter.

This subroutine may fail while interpreting the request, or while
processing the request.

=cut

sub respond {
    my ($self, $responder, $env) = @_;
    if ($env->{REQUEST_METHOD} eq 'OPTIONS') {
        my %cors = ( 
            'Content-Type' => 'text/plain',
            'Allow-Origin' => "",
            'Allow-Methods' => "GET,POST",
            'Allow-Headers' => "origin,x-requested-with,content-type",
            'Max-Age' => 60*60*24 );
        if (ref $self->{config}{CORS} eq 'HASH') {
            for my $key (keys %cors) {
                $cors{$key} = $self->{config}{CORS}{$key} // $cors{$key};
            }
        } else {
            $cors{Origin} = $self->{config}{CORS};
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
            $service = $self->service($responder, $env);
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

This method does a preliminary interpretation of the request and
converts it into a service object, which is returned. The contents of
the configuration are cloned into the service object.

The returned service object contains

  config => a clone of the configuration for this type of service
  env => the PSGI environment

and may contain

  posted => XML::LibXML DOM document element of the posted data
  filter => XML::LibXML DOM document element of the filter
  parameters => hash of rquest parameters obtained from Plack::Request

Note: all keys in request parameters are converted to lower case in
parameters.

This subroutine may fail due to a request for an unknown service. The
error is reported as an XML message using OGC conventions.

=cut

sub service {
    my ($self, $responder, $env) = @_;

    my $service = { env => $env };

    my $request = Plack::Request->new($env);
    my $parameters = $request->parameters;
    
    my %names;
    for my $key (sort keys %$parameters) {
        $names{lc($key)} = $key;
    }

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
        $service->{posted} = $dom->documentElement();
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
                $service->{filter} = $dom->documentElement();
            } else {
                $service->{parameters}{$key} = $parameters->{$names{$key}};
            }
        }
    }

    # service may also be an attribute in the top element of posted XML
    my $service_from_posted = sub {
        my $node = shift;
        return undef unless $node;
        return $node->getAttribute('service');
    };

    # RESTful way to define the service
    my $service_from_script_name = sub {
        my $env = shift;
        my ($script_name) = $env->{SCRIPT_NAME} =~ /(\w+)$/;
        return $script_name;
    };

    my $requested_service = $parameters->{service} // 
        $service_from_posted->($service->{posted}) // 
        $service_from_script_name->($env) // ''; 

    if (exists $self->{services}{$requested_service}) {
        $service->{service} = $requested_service;
        $service->{config} = get_config($self->{config}, $requested_service);
        return bless $service, $self->{services}{$requested_service};
    }

    error($responder, { exceptionCode => 'InvalidParameterValue',
                        locator => 'service',
                        ExceptionText => "'$requested_service' is not a known service to this server" } );
    return undef;
}

sub get_config {
    my ($config, $service) = @_;
    if (exists $config->{$service}) {
        if (ref $config->{$service}) {
            return $config->{$service};
        }
        if (ref $config->{$config->{$service}}) {
            return $config->{$config->{$service}};
        }
        return undef;
    }
    return $config;
}

=pod

=head3 error($responder, $msg)

Stream an error report as an XML message of type

  <?xml version="1.0" encoding="UTF-8"?>
  <ExceptionReport>
      <Exception exceptionCode="$msg->{exceptionCode}" locator="$msg->{locator}">
          <ExceptionText>$msg->{ExceptionText}<ExceptionText>
      <Exception>
  </ExceptionReport>

=cut

sub error {
    my ($responder, $msg) = @_;
    my $writer = Geo::OGC::Service::XMLWriter::Caching->new();
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

=head1 Geo::OGC::Service::Common

A base type for all OGC services.

=head2 SYNOPSIS

  $service->DescribeService($writer);
  $service->Operation($writer, $operation, $protocols, $parameters);

=head2 DESCRIPTION

The class contains methods for common tasks for all services.

=head2 METHODS

=cut

package Geo::OGC::Service::Common;
use Modern::Perl;

=pod

=head3 DescribeService($writer)

Create ows:ServiceIdentification and ows:ServiceProvider elements.

=cut

sub DescribeService {
    my ($self, $writer) = @_;
    $writer->element('ows:ServiceIdentification', 
                     [['ows:Title' => $self->{config}{Title} // "Yet another $self->{service} server"],
                      ['ows:Abstract' => $self->{config}{Abstract} // ''],
                      ['ows:ServiceType', {codeSpace=>"OGC"}, "OGC $self->{service}"],
                      ['ows:ServiceTypeVersion', $self->{config}{ServiceTypeVersion} // '1.0.0'],
                      ['ows:Fees' => $self->{config}{Fees} // 'NONE'],
                      ['ows:AccessConstraints' => $self->{config}{AccessConstraints} // 'NONE']]);
    $writer->element('ows:ServiceProvider',
                     [['ows:ProviderName' => $self->{config}{ProviderName} // 'Nobody in particular'],
                      ['ows:ProviderSite', { 'xlink:type'=>"simple", 
                                             'xlink:href' => $self->{config}{ProviderSite} // '' }],
                      ['ows:ServiceContact' => $self->{config}{ServiceContact}]]);
}

=pod

=head3 Operation($writer, $operation, $protocols, $parameters)

Create ows:Operation element and its ows:DCP and ows:Parameter sub
elements.

=cut

sub Operation {
    my ($self, $writer, $operation, $protocols, $parameters) = @_;
    my @parameters;
    for my $p (@$parameters) {
        for my $n (keys %$p) {
            my @values;
            for my $v (@{$p->{$n}}) {
                push @values, ['ows:Value', $v];
            }
            push @parameters, ['ows:Parameter', {name=>$n}, \@values];
        }
    }
    my $constraint;
    $constraint = [ 'ows:Constraint' => {name => 'GetEncoding'}, $protocols->{Get} ] if ref $protocols->{Get};
    my @http;
    push @http, [ 'ows:Get' => { 'xlink:type'=>'simple', 'xlink:href'=>$self->{config}{resource} }, $constraint ]
        if $protocols->{Get};
    push @http, [ 'ows:Post' => { 'xlink:type'=>'simple', 'xlink:href'=>$self->{config}{resource} } ]
        if $protocols->{Post};
    $writer->element('ows:Operation' => { name => $operation }, [['ows:DCP' =>['ows:HTTP' => \@http ]], @parameters]);
}

=pod

=head1 Geo::OGC::Service::XMLWriter

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

  my $writer = Geo::OGC::Service::XMLWriter::Streaming->new($responder);
  $writer->prolog;
  $writer->open_element('MyXML');
  while (a long time) {
      $writer->element('MyElement');
  }
  $writer->close_element;
  # $writer is closed when it goes out of scope

=head2 DESCRIPTION

The classes Geo::OGC::Service::XMLWriter (abstract),
Geo::OGC::Service::XMLWriter::Streaming (concrete), and
Geo::OGC::Service::XMLWriter::Caching (concrete) are provided as a
convenience for writing XML to the client.

The element method has the syntax

  $writer->xml_element($tag[, $attributes][, $content])

$attributes is a reference to a hash

$content is a reference to a list of xml elements (tag...)

Setting $tag to 1, allows writing plain content.

If $attribute{$key} is undefined the attribute is not written at all.

=cut

package Geo::OGC::Service::XMLWriter;
use Modern::Perl;
use Encode qw(decode encode is_utf8);

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
    if ($element =~ /^1/) {
        $self->write($content);
        return;
    }
    $self->write("<$element");
    if ($attributes) {
        for my $a (keys %$attributes) {
            my $attr = $attributes->{$a};
            if (defined $attr) {
                $attr = decode utf8 => $attr unless is_utf8($attr);
                $self->write(" $a=\"$attr\"");
            }
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
            $content = decode utf8 => $content unless is_utf8($content);
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
            my $attr = $attributes->{$a};
            if (defined $attr) {
                $attr = decode utf8 => $attr unless is_utf8($attr);
                $self->write(" $a=\"$attr\"");
            }
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

=pod

=head1 Geo::OGC::Service::XMLWriter::Streaming

A helper class for writing XML into a stream.

=head2 SYNOPSIS

  my $w = Geo::OGC::Service::XMLWriter::Streaming($responder, $content_type, $declaration);

Using $w as XMLWriter sets writer, which is obtained from $responder,
to write XML. The writer is closed when $w is destroyed.

$content_type and $declaration are optional. The defaults are
'text/xml; charset=utf-8' and '<?xml version="1.0"
encoding="UTF-8"?>'.

=cut

package Geo::OGC::Service::XMLWriter::Streaming;
use Modern::Perl;

our @ISA = qw(Geo::OGC::Service::XMLWriter Plack::Util::Prototype); # can't use parent since Plack is not yet

sub new {
    my ($class, $responder, $content_type, $declaration) = @_;
    $content_type //= 'text/xml; charset=utf-8';
    my $self = $responder->([200, [ 'Content-Type' => $content_type ]]);
    $self->{declaration} = $declaration //= '<?xml version="1.0" encoding="UTF-8"?>';
    return bless $self, $class;
}

sub prolog {
    my $self = shift;
    $self->write($self->{declaration});
}

sub DESTROY {
    my $self = shift;
    $self->close;
}

=pod

=head1 Geo::OGC::Service::XMLWriter::Caching

A helper class for writing XML into a cache.

=head2 SYNOPSIS

 my $w = Geo::OGC::Service::XMLWriter::Caching($content_type, $declaration);
 $w->stream($responder);

Using $w to produce XML caches the XML. The cached XML can be
written by a writer obtained from a $responder.

$content_type and $declaration are optional. The defaults are as in
Geo::OGC::Service::XMLWriter::Streaming.

=cut

package Geo::OGC::Service::XMLWriter::Caching;
use Modern::Perl;

our @ISA = qw(Geo::OGC::Service::XMLWriter);

sub new {
    my ($class, $content_type, $declaration) = @_;
    my $self = {
        cache => [],
        content_type => $content_type //= 'text/xml; charset=utf-8',
        declaration => $declaration //= '<?xml version="1.0" encoding="UTF-8"?>'
    };
    $self->{cache} = [];
    return bless $self, $class;
}

sub write {
    my $self = shift;
    my $line = shift;
    push @{$self->{cache}}, $line;
}

sub to_string {
    my $self = shift;
    my $xml = $self->{declaration};
    for my $line (@{$self->{cache}}) {
        $xml .= $line;
    }
    return $xml;
}

sub stream {
    my $self = shift;
    my $responder = shift;
    my $debug = shift;
    my $writer = $responder->([200, [ 'Content-Type' => $self->{content_type} ]]);
    $writer->write($self->{declaration});
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
