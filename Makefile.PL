use 5.022000;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Geo::OGC::Service',
    VERSION_FROM      => 'lib/Geo/OGC/Service.pm', # finds $VERSION, requires EU::MM from perl >= 5.5
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ABSTRACT_FROM     => 'lib/Geo/OGC/Service.pm', # retrieve abstract from module
    AUTHOR            => 'Ari Jolma <ari.jolma at gmail.com>',
    LICENSE           => 'perl'
);
