package HTTP::MultiPart::Parser;
use 5.008005;
use strict;
use warnings;

our $VERSION = "0.01";

use File::Spec ();
use File::Temp ();
use Hash::MultiValue ();
use Carp ();

use constant {
    STATE_PREAMBLE => 1,
    STATE_BOUNDARY => 2,
    STATE_HEADER   => 3,
    STATE_BODY     => 4,
    STATE_DONE     => 5,
};
my $CRLF = "\x0D\x0A";

sub new {
    my $class = shift;
    my %args = @_==1 ? %{$_[0]} : @_;

    unless (exists $args{content_type}) {
        Carp::croak("Missing mandatory parameter: content_type");
    }

    my $content_type = $args{content_type};
    unless ( $content_type =~ /boundary=\"?([^\";]+)\"?/ ) {
        Carp::croak("Invalid boundary in content_type: '$content_type'");
    }

    bless {
        boundary => $1,
        state    => STATE_PREAMBLE,
        params   => Hash::MultiValue->new(),
        files    => Hash::MultiValue->new(),
        tmpdir   => exists($args{tmpdir}) ? $args{tmpdir} : File::Spec->tmpdir,
        length   => 0, # Does it needed?
    }, $class;
}

sub params { $_[0]->{params} }
sub files  { $_[0]->{files} }

sub add {
    my $self = shift;
    $self->{buffer} .= $_[0];
    $self->{length} += length($_[0]);

    while (1) {
        if ($self->{state} == STATE_PREAMBLE) {
            return unless $self->parse_preamble();
        } elsif ($self->{state} == STATE_BOUNDARY) {
            return unless $self->parse_boundary();
        } elsif ($self->{state} == STATE_HEADER) {
            return unless $self->parse_header();
        } elsif ($self->{state} == STATE_BODY) {
            return unless $self->parse_body();
        } else {
            Carp::croak('Unknown state');
        }
    }
}

sub parse_preamble {
    my $self = shift;

    my $index = index( $self->{buffer}, "--$self->{boundary}" );

    unless ( $index >= 0 ) {
        return 0;
    }

    # replace preamble with CRLF so we can match dash-boundary as delimiter
    substr( $self->{buffer}, 0, $index, $CRLF );

    $self->{state} = STATE_BOUNDARY;

    return 1;
}

sub parse_boundary {
    my $self = shift;

    if ( index( $self->{buffer}, "${CRLF}--$self->{boundary}${CRLF}" ) == 0 ) {
        substr( $self->{buffer}, 0, length( "${CRLF}--$self->{boundary}${CRLF}" ), '' );
        $self->{part}  = {};
        $self->{state} = STATE_HEADER;

        return 1;
    }

    my $delimiter_end = "${CRLF}--$self->{boundary}--${CRLF}";
    if ( index( $self->{buffer}, $delimiter_end ) == 0 ) {

        substr( $self->{buffer}, 0, length( $delimiter_end ), '' );
        $self->{part}  = {};
        $self->{state} = STATE_DONE;

        return 0;
    }

    return 0;
}

sub parse_header {
    my $self = shift;

    my $index = index( $self->{buffer}, $CRLF . $CRLF );

    unless ( $index >= 0 ) {
        return 0;
    }

    my $header = substr( $self->{buffer}, 0, $index );

    substr( $self->{buffer}, 0, $index + 4, '' );

    my @headers;
    for ( split /$CRLF/, $header ) {
        if (s/\A[ \t]+//) {
            $headers[-1] .= $_;
        } else {
            push @headers, $_;
        }
    }

    my $token = qr/[^][\x00-\x1f\x7f()<>@,;:\\"\/?={} \t]+/;

    for my $header (@headers) {

        $header =~ s/^($token):[\t ]*//;

        ( my $field = $1 ) =~ s/\b(\w)/uc($1)/eg;

        if ( exists $self->{part}->{headers}->{$field} ) {
            for ( $self->{part}->{headers}->{$field} ) {
                $_ = [$_] unless ref($_) eq "ARRAY";
                push( @$_, $header );
            }
        }
        else {
            $self->{part}->{headers}->{$field} = $header;
        }
    }

    $self->{state} = STATE_BODY;

    return 1;
}

sub parse_body {
    my $self = shift;

    my $boundary = $self->{boundary};

    my $index = index( $self->{buffer}, "${CRLF}--${boundary}" );

    if ( $index < 0 ) {

        # make sure we have enough buffer to detect end delimiter
        #
        my $delimiter_end = "${CRLF}--${boundary}--";
        my $length = length( $self->{buffer} ) - ( length( $delimiter_end ) + 2 );

        unless ( $length > 0 ) {
            return 0;
        }

        $self->{part}->{data} .= substr( $self->{buffer}, 0, $length, '' );
        $self->{part}->{size} += $length;

        $self->handler( $self->{part}, 0 );

        return 0;
    } else {
        $self->{part}->{data} .= substr( $self->{buffer}, 0, $index, '' );
        $self->{part}->{size} += $index;

        $self->handler( $self->{part}, 1 );

        $self->{state} = STATE_BOUNDARY;

        return 1;
    }
}

sub handler {
    my ( $self, $part, $done ) = @_;

    unless ( exists $part->{name} ) {

        my $disposition = $part->{headers}->{'Content-Disposition'};
        my ($name)      = $disposition =~ / name="?([^\";]+)"?/;
        my ($filename)  = $disposition =~ / filename="?([^\"]*)"?/;
        # Need to match empty filenames above, so this part is flagged as an upload type

        $part->{name} = $name;

        if ( defined $filename ) {
            $part->{filename} = $filename;

            if ( $filename ne "" ) {
                my $basename = (File::Spec->splitpath($filename))[2];
                my $suffix = $basename =~ /[^.]+(\.[^\\\/]+)$/ ? $1 : q{};

                my $fh = File::Temp->new(
                    UNLINK => 1,
                    DIR    => $self->{tmpdir},
                    SUFFIX => $suffix,
                );

                $part->{fh}       = $fh;
                $part->{tempname} = $fh->filename;
            }
        }
    }

    if ( $part->{fh} && ( my $length = length( $part->{data} ) ) ) {
        $part->{fh}->write( substr( $part->{data}, 0, $length, '' ), $length );
    }

    if ( $done ) {
        if ( exists $part->{filename} ) {
            if ( $part->{filename} ne "" ) {
                $part->{fh}->close if defined $part->{fh};

                delete @{$part}{qw[ data fh ]};

                $self->files->add( $part->{name}, $part );
            }
        }
        else {
            $self->params->add( $part->{name}, $part->{data} );
        }
    }
}

# Note.
#
# I dropped `param_order` feature from this module. Because it's useless.
# But if you want to add this feature, I can apply your patch.

1;
__END__

=encoding utf-8

=head1 NAME

HTTP::MultiPart::Parser - multipart/form-data parser library

=head1 SYNOPSIS

    use HTTP::MultiPart::Parser;

    my $parser = HTTP::MultiPart::Parser->new();
    while (my $buffer = read_from_buffer()) {
        $parser->add($buffer);
    }

    $parser->params();  # Parameters
    $parser->files();   # Uploaded files

=head1 DESCRIPTION

HTTP::MultiPart::Parser is low level `multipart/form-data` parser library.

=head1 MOTIVATION

HTTP::Body is the great `multipart/form-data` parsing library. But I need more crushed, tiny library.

=head1 METHODS

=over 4

=item C<< my $parser = HTTP::MultiPart::Parser->new() >>

Create new instance.

=item C<< $parser->add($buffer:Str) >>

Add contents for parsing buffer. HTTP::MultiPart parses contents incrementally.

=item C<< $parser->parts : ArrayRef >>

=item C<< $parser->params : Hash::MultiValue >>

Parameters. The type is Hash::MultiValue.

Key is a field name, value is a string.

=item C<< $parser->files :Hash::MultiValue >>

Uploaded files. The type is Hash::MultiValue.

Key is a field name, value is a HashRef.

=back

=head1 FAQ

=over 4

=item DOES THIS MODULE CARE THE CHUNKED DATA?

No. If you want to support chunked data.
But you can use L<HTTP::Chunked> for handling chunked data.

=back

=head1 LICENSE

Copyright (C) tokuhirom.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

And Christian Hansen, "chansen@cpan.org"

=head1 THANKS TO

Most of the code was taken from L<HTTP::Body::MultiPart>, thank you Christian Hansen!

=head1 SEE ALSO

L<HTTP::Body>

=head1 AUTHOR

tokuhirom E<lt>tokuhirom@gmail.comE<gt>

And HTTP::Body author: Christian Hansen, "chansen@cpan.org"

=cut

