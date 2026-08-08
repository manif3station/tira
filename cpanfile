requires 'Data::TOON', '0.03';
requires 'YAML::PP', '0.039';
requires 'Dancer2', '1.1.2';
requires 'Plack', '1.0051';

# EPIC-457 records notification history beside the project file, so the
# escalation level can be counted rather than written onto the card.
requires 'DBD::SQLite', '1.70';

# Optional: any release emitting byte-identical output works; t/38 verifies
# the installed one. Without it Tira falls back to core JSON::PP.
recommends 'Cpanel::JSON::XS', '4.19';

on test => sub {
    # A real pseudo-terminal, so the line editor's terminal handling is
    # covered by exercising it rather than by excluding it.
    requires 'IO::Tty', '0';
    requires 'Pod::Checker', '0';
    requires 'Test::More', '0.98';
    requires 'HTTP::Request::Common', '0';
};
