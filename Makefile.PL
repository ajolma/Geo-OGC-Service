use 5.010000;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Geo::OGC::Service',
    VERSION_FROM      => 'lib/Geo/OGC/Service.pm', # finds $VERSION, requires EU::MM from perl >= 5.5
    PREREQ_PM         => { "Modern::Perl" => 0,
                           "Plack::Request" => 0,
                           "Plack::Builder" => 0,
                           "JSON" => 0,
                           Encode => 0,
                           "XML::LibXML" => 0,
                           "XML::LibXML::PrettyPrint" => 0, # for debugging
                           "Clone" => 0 },
    TEST_REQUIRES     => { "Plack::Test" => 0,
                           "HTTP::Request::Common" => 0 },
    ABSTRACT_FROM     => 'lib/Geo/OGC/Service.pm', # retrieve abstract from module
    AUTHOR            => 'Ari Jolma <ari.jolma at gmail.com>',
    LICENSE           => 'perl'
);
