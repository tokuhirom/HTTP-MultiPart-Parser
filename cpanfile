requires 'perl', '5.008005';
requires 'File::Temp';
requires 'File::Spec';
requires 'Carp';

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Hash::MultiValue';
    requires 'Test::Deep';
};

