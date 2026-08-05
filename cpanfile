requires 'Data::TOON', '0.03';
requires 'YAML::PP', '0.039';

on test => sub {
    requires 'Pod::Checker', '0';
    requires 'Test::More', '0.98';
};
