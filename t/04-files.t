use warnings;
use strict;

use Test::More;

use Ogg::Vorbis::Header::PurePerl;

open my $ogg_fh, '<', 't/test.ogg';

my $ogg = Ogg::Vorbis::Header::PurePerl->new($ogg_fh);
ok($ogg, 'Create object from a filehandle');
isa_ok($ogg, 'Ogg::Vorbis::Header::PurePerl');

done_testing();
