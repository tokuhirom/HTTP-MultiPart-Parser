#!perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Test::Deep;

use Cwd;
use HTTP::MultiPart::Parser;
use File::Spec::Functions;
use IO::File;
use PAML;
use File::Temp qw/ tempdir /;

my $path = catdir( getcwd(), 't', 'data', 'multipart' );

for ( my $i = 1; $i <= 13; $i++ ) {
    next if $i == 12; # chunked.

    subtest "test number: $i" => sub {

    my $test    = sprintf( "%.3d", $i );
    my $headers = PAML::LoadFile( catfile( $path, "$test-headers.pml" ) );
    my $results = PAML::LoadFile( catfile( $path, "$test-results.pml" ) );
    my $content = IO::File->new( catfile( $path, "$test-content.dat" ) );
    my $tempdir = tempdir( 'XXXXXXX', CLEANUP => 1, DIR => File::Spec->tmpdir() );
    my $body    = HTTP::MultiPart::Parser->new(
        content_type => $headers->{'Content-Type'},
        tmpdir       => $tempdir,
    );

    my $regex_tempdir = quotemeta($tempdir);

    binmode $content, ':raw';

    while ( $content->read( my $buffer, 1024 ) ) {
        $body->add($buffer);
    }
    
    # Save tempnames for later deletion
    my @temps;
    
    for my $field ( sort keys %{ $body->files } ) {
        note "Field: $field";

        my $value = $body->files->as_hashref_mixed->{$field};

        for ( ( ref($value) eq 'ARRAY' ) ? @{$value} : $value ) {
            like($_->{tempname}, qr{$regex_tempdir}, "has tmpdir $tempdir");
            push @temps, $_->{tempname};
        }
        
        # Tell Test::Deep to ignore tempname values
        if ( ref $value eq 'ARRAY' ) {
            for ( @{ $results->{upload}->{$field} } ) {
                $_->{tempname} = ignore();
            }
        }
        else {
            $results->{upload}->{$field}->{tempname} = ignore();
        }
    }
	
    cmp_deeply( undef, $results->{body}, "$test MultiPart body" );
    # cmp_deeply( $body->body, $results->{body}, "$test MultiPart body" );
    cmp_deeply( $body->params->as_hashref_mixed, $results->{param}, "$test MultiPart param" );
    # cmp_deeply( $body->param_order, $results->{param_order} ? $results->{param_order} : [], "$test MultiPart param_order" );
    cmp_deeply( $body->files->as_hashref_mixed, $results->{upload}, "$test MultiPart upload" )
        if $results->{upload};
    cmp_ok( $body->{state}, 'eq', HTTP::MultiPart::Parser::STATE_DONE, "$test MultiPart state" );
    cmp_ok( $body->{length}, '==', $headers->{'Content-Length'}, "$test MultiPart length" );
    
    undef $body;
    
    # Ensure temp files were deleted
    for my $temp ( @temps ) {
        ok( !-e $temp, "Temp file $temp was deleted" );
    }

    };
} 

done_testing;
