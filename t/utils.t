use strict;
use warnings;
use utf8;
no warnings 'utf8' ;

use Test::More tests => 19;
use Biber;
use Biber::Entry::Name;
use Biber::Entry::Names;
use Biber::Utils;
use Biber::LaTeX::Recode;
use Log::Log4perl qw(:easy);
use IPC::Cmd qw( can_run run );
use Cwd;
my $cwd = getcwd;

Log::Log4perl->easy_init($ERROR);
my $biber = Biber->new(noconf => 1);

# File locating
# Using File::Spec->canonpath() to normalise path separators so these tests work
# on Windows/non-Windows
# Absolute path
is(File::Spec->canonpath(locate_biber_file("$cwd/t/tdata/general1.bcf")), File::Spec->canonpath("$cwd/t/tdata/general1.bcf"), 'File location - 1');
# Relative path
is(File::Spec->canonpath(locate_biber_file('t/tdata/general1.bcf')), File::Spec->canonpath('t/tdata/general1.bcf'), 'File location - 2');
# Same place as control file
Biber::Config->set_ctrlfile_path('t/tdata/general1.bcf');
is(File::Spec->canonpath(locate_biber_file('t/tdata/examples.bib')), File::Spec->canonpath('t/tdata/examples.bib'), 'File location - 3');

# The \cM* is there because if cygwin picks up miktex kpsewhich, it will return a path
# with a Ctrl-M on the end
# Testing using a file guaranteed to be installed with any latex install
SKIP: {
  skip "No LaTeX installation", 1 unless can_run('kpsewhich');
  # using kpsewhich
  like(File::Spec->canonpath(locate_biber_file('plain.tex')), qr|plain.tex\cM*\z|, 'File location - 4');
    }

# In output_directory
Biber::Config->setoption('output_directory', 't/tdata');
is(File::Spec->canonpath(locate_biber_file('general1.bcf')), File::Spec->canonpath("t/tdata/general1.bcf"), 'File location - 5');

# String normalising
is( normalise_string('"a, b–c: d" ', 1),  'a bc d', 'normalise_string' );

Biber::Config->setoption('bblencoding', 'latin1');
is( normalise_string_underscore('\c Se\x{c}\"ok-\foo{a},  N\`i\~no
    $§+ :-)   ', 1), 'Secoka_Nino', 'normalise_string_underscore 1' );

Biber::Config->setoption('bblencoding', 'UTF-8');
is( normalise_string_underscore('\c Se\x{c}\"ok-\foo{a},  N\`i\~no
    $§+ :-)   ', 0), 'Şecöka_Nìño', 'normalise_string_underscore 2' );

is( normalise_string_underscore('{Foo de Bar, Graf Ludwig}', 1), 'Foo_de_Bar_Graf_Ludwig', 'normalise_string_underscore 2');

# LaTeX decoding
is( latex_decode('Mu\d{h}ammad ibn M\=us\=a al-Khw\=arizm\={\i}'), 'Muḥammad ibn Mūsā al-Khwārizmī', 'latex decode 1');
is( latex_decode('\alpha'), '\alpha', 'latex decode 2'); # no greek decoding by default
is( latex_decode('\alpha', scheme => 'full'), 'α', 'Latex decode 3'); # greek decoding with "full"

# LaTeX encoding
is( latex_encode('Muḥammad ibn Mūsā al-Khwārizmī'), 'Mu\d{h}ammad ibn M\={u}s\={a} al-Khw\={a}rizm\={\i}', 'latex encode 1');
is( latex_encode('α'), 'α', 'latex encode 2'); # no greek encoding by default
is( latex_encode('α', scheme => 'full'), '{$\alpha$}', 'latex encode 3'); # greek encoding with "full"

my $names = bless [
    (bless { namestring => '\"Askdjksdj, Bsadk Cklsjd', nameinitstring => '\"Askdjksdj, BC' }, 'Biber::Entry::Name'),
    (bless { namestring => 'von Üsakdjskd, Vsajd W\`asdjh', nameinitstring => 'v Üsakdjskd, VW'}, 'Biber::Entry::Name'),
    (bless { namestring => 'Xaskldjdd, Yajs\x{d}ajks~Z.', nameinitstring => 'Xaskldjdd, YZ'}, 'Biber::Entry::Name'),
    (bless { namestring => 'Maksjdakj, Nsjahdajsdhj', nameinitstring => 'Maksjdakj, N'  }, 'Biber::Entry::Name')
], 'Biber::Entry::Names';

is( makenameid($names), 'Äskdjksdj_Bsadk_Cklsjd_von_Üsakdjskd_Vsajd_Wàsdjh_Xaskldjdd_Yajsdajks_Z_Maksjdakj_Nsjahdajsdhj', 'makenameid' );

my @arrayA = qw/ a b c d e f c /;
my @arrayB = qw/ c e /;
my @AminusB = reduce_array(\@arrayA, \@arrayB);
my @AminusBexpected = qw/ a b d f /;

is_deeply(\@AminusB, \@AminusBexpected, 'reduce_array') ;

is(remove_outer('{Some string}'), 'Some string', 'remove_outer') ;

is( normalise_string_hash('Ä.~{\c{C}}.~{\c S}.'), 'Äc:Cc:S', 'normalise_string_lite' ) ;

