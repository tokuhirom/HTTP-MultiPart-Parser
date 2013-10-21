package HTTP::MultiPart::Parser;
use 5.008005;
use strict;
use warnings;

our $VERSION = "0.01";

use File::Spec ();
use File::Temp ();
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
        tmpdir   => exists($args{tmpdir}) ? $args{tmpdir} : File::Spec->tmpdir,
        parts    => [],
        length   => 0, # Does it needed?
    }, $class;
}

sub parts { $_[0]->{parts} }

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
                my $suffix = $basename =~ /(\.[a-zA-Z0-9_-]+)\z/ ? $1 : q{};

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

                push @{ $self->{parts} },
                  +{
                    name     => $part->{name},
                    size     => $part->{size},
                    headers  => $part->{headers},
                    filename => $part->{filename},
                    tempname => $part->{tempname},
                  };
                $part;
            }
        }
        else {
            push @{$self->{parts}}, +{
                name => $part->{name},
                data => $part->{data},
            };
        }
    }
}


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

    $parser->parts();  # Parts.

=head1 DESCRIPTION

HTTP::MultiPart::Parser is low level `multipart/form-data` parser library.

=head1 MOTIVATION

HTTP::Body::MultiPart is the great `multipart/form-data` parsing library. But I need more crushed, tiny library.

=head1 METHODS

=over 4

=item C<< my $parser = HTTP::MultiPart::Parser->new(%args) >>

Create new instance.

Arguments are:

=over 4

=item content_type: Str

This is a Content-Type header in main header.

Thie argument is the mandatory parameter.

=item tmpdir: Str

The directory to save temporary file.

Default: C< File::Temp->tmpdir >.

=back

=item C<< $parser->add($buffer:Str) >>

Add contents for parsing buffer. HTTP::MultiPart parses contents incrementally.

=item C<< $parser->parts : ArrayRef >>

It returns C< ArrayRef[HashRef] >.

Normal type part contains following keys:

=over 4

=item name

The name of the part.

=item data

Body of the part. If the hashref contains C<filename> key, this key does not exist.

=back

File type part contains following keys:

=over 4

=item name

The name of the part.

=item headers

Headers for this part in HashRef. It's I<mixed>. It means some values are Str, some values are ArrayRef[Str].

=item filename

File name specified by C<Content-Disposition> header.

=item tempname

File name for the temporary file, that contains the body.

=item size

Size of the part.

=back

=back

=head1 FAQ

=over 4

=item DOES THIS MODULE CARE THE CHUNKED DATA?

No.

I wrote this module for PSGI server applications.

Normally, PSGI server do dechunking automatically. Your application don't need to care the chunked data.

    This is rather a long issue to reply individually, but in general, dechunking HTTP request should be done on the HTTP server level (be it frontend server like nginx, or PSGI server such as Starman), and on PSGI level, psgi.input should return the decoded body (and ideally Content-Length header should point to the right value) i.e. transparent to the hosted PSGI application.
    https://github.com/plack/Plack/issues/404

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

