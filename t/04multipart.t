#!perl

use strict;
use warnings;

# This test case is taken from HTTP::Body... Thanks!

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Test::Deep;
use Hash::MultiValue ();

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

    binmode $content, ':raw';

    while ( $content->read( my $buffer, 1024 ) ) {
        $body->add($buffer);
    }

    # Save tempnames for later deletion check
    my @temps = map { $_->{tempname} } grep { defined $_->{tempname} } @{$body->parts};
    for my $tempfile ( @temps ) {
        ok starts_with($tempfile, $tempdir), "has tmpdir $tempdir";
    }

    for my $field ( sort keys %{$results->{upload}} ) {
        my $value = $results->{upload}->{$field};

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
	
    my $upload = Hash::MultiValue->new();
    my $params = Hash::MultiValue->new();
    for (@{$body->parts}) {
        if (exists $_->{filename}) {
            $upload->add($_->{name}, $_);
        } else {
            $params->add($_->{name}, $_->{data});
        }
    }
    cmp_deeply( $params->as_hashref_mixed, $results->{param}, "$test MultiPart param" );
    cmp_deeply(
        [map { $_->{name} } grep { !$_->{tempname} } @{$body->parts}],
        $results->{param_order} || [],
        'MultiPart param_order'
    );
    if ($results->{upload}) {
        cmp_deeply( $upload->as_hashref_mixed, $results->{upload}, "$test MultiPart upload" );
    }
    is( $body->{state}, HTTP::MultiPart::Parser::STATE_DONE, "$test MultiPart state" );
    is( $body->{length}, $headers->{'Content-Length'}, "$test MultiPart length" );
    
    undef $body;
    
    # Ensure temp files were deleted
    for my $temp ( @temps ) {
        ok( !-e $temp, "Temp file $temp was deleted" );
    }

    };
} 

done_testing;

sub starts_with { $_[0] =~ qr{\A$_[1]} }

