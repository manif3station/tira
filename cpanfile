requires 'Data::TOON', '0.03';
requires 'YAML::PP', '0.039';
requires 'Dancer2', '1.1.2';
requires 'Plack', '1.0051';

on test => sub {
    requires 'Pod::Checker', '0';
    requires 'Test::More', '0.98';
    requires 'HTTP::Request::Common', '0';
};
