
# NAME

HTTP::MultiPart::Parser - multipart/form-data parser library

# SYNOPSIS

    use HTTP::MultiPart::Parser;

    my $parser = HTTP::MultiPart::Parser->new();
    while (my $buffer = read_from_buffer()) {
        $parser->add($buffer);
    }

    $parser->parts();  # Parts.

# DESCRIPTION

HTTP::MultiPart::Parser is low level \`multipart/form-data\` parser library.

# MOTIVATION

HTTP::Body::MultiPart is the great \`multipart/form-data\` parsing library. But I need more crushed, tiny library.

# METHODS

- `my $parser = HTTP::MultiPart::Parser->new(%args)`

    Create new instance.

    Arguments are:

    - content\_type: Str

        This is a Content-Type header in main header.

        Thie argument is the mandatory parameter.

    - tmpdir: Str

        The directory to save temporary file.

        Default: ` File::Temp-`tmpdir >.

- `$parser->add($buffer:Str)`

    Add contents for parsing buffer. HTTP::MultiPart parses contents incrementally.

- `$parser->parts : ArrayRef`

    It returns ` ArrayRef[HashRef] `.

    Normal type part contains following keys:

    - name

        The name of the part.

    - data

        Body of the part. If the hashref contains `filename` key, this key does not exist.

    File type part contains following keys:

    - name

        The name of the part.

    - headers

        Headers for this part in HashRef. It's _mixed_. It means some values are Str, some values are ArrayRef\[Str\].

    - filename

        File name specified by `Content-Disposition` header.

    - tempname

        File name for the temporary file, that contains the body.

    - size

        Size of the part.

# FAQ

- DOES THIS MODULE CARE THE CHUNKED DATA?

    No.

    I wrote this module for PSGI server applications.

    Normally, PSGI server do dechunking automatically. Your application don't need to care the chunked data.

        This is rather a long issue to reply individually, but in general, dechunking HTTP request should be done on the HTTP server level (be it frontend server like nginx, or PSGI server such as Starman), and on PSGI level, psgi.input should return the decoded body (and ideally Content-Length header should point to the right value) i.e. transparent to the hosted PSGI application.
        https://github.com/plack/Plack/issues/404

# LICENSE

Copyright (C) tokuhirom.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

And Christian Hansen, "chansen@cpan.org"

# THANKS TO

Most of the code was taken from [HTTP::Body::MultiPart](http://search.cpan.org/perldoc?HTTP::Body::MultiPart), thank you Christian Hansen!

# SEE ALSO

[HTTP::Body](http://search.cpan.org/perldoc?HTTP::Body)

# AUTHOR

tokuhirom <tokuhirom@gmail.com>

And HTTP::Body author: Christian Hansen, "chansen@cpan.org"
