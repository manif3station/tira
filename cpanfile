requires 'Data::TOON', '0.03';
requires 'YAML::XS', '0.83';
requires 'Dancer2', '1.1.2';
requires 'Plack', '1.0051';

# The board is served by Starman, plain or over TLS. The single-connection
# server it used to use stopped answering entirely while one connection was
# held open, and a board that accepts a connection and never answers looks
# exactly like a board that is fine.
requires 'Starman', '0.4014';

# EPIC-457 records notification history beside the project file, so the
# escalation level can be counted rather than written onto the card.
requires 'DBD::SQLite', '1.70';

# Required, not preferred. The owner's rule of 2026-08-12: no pure-Perl
# parsers where a compiled one exists. Decoding a mature board cost 1992ms
# with the pure-Perl parser and 6ms with this one - the parser was the board
# walk. It needs a compiler at install time, which is the price of that.
requires 'Cpanel::JSON::XS', '4.19';

on test => sub {
    # A real pseudo-terminal, so the line editor's terminal handling is
    # covered by exercising it rather than by excluding it.
    requires 'IO::Tty', '0';
    requires 'Pod::Checker', '0';
    requires 'Test::More', '0.98';
    requires 'HTTP::Request::Common', '0';
};
