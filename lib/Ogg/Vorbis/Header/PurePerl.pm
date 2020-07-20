package Ogg::Vorbis::Header::PurePerl;

use 5.006;
use strict;
use warnings;

# First four bytes of stream are always OggS
use constant OGGHEADERFLAG => 'OggS';

our $VERSION = '1.03';

sub new {
	my $class = shift;
	my $file  = shift;

	my %data  = ();

	if (ref $file) {
		binmode $file;

		%data = (
			'filesize'   => -s $file,
			'fileHandle' => $file,
		);

	} else {

		open my $fh, '<', $file or do {
			warn "$class: File $file does not exist or cannot be read: $!";
			return undef;
		};

		# make sure dos-type systems can handle it...
		binmode $fh;

		%data = (
			'filename'   => $file,
			'filesize'   => -s $file,
			'fileHandle' => $fh,
		);
	}

	if ( _init(\%data) ) {
		_load_info(\%data);
		_load_comments(\%data);
		_calculate_track_length(\%data);
	}

	undef $data{'fileHandle'};

	return bless \%data, $class;
}

sub info {
	my $self = shift;
	my $key = shift;

	# if the user did not supply a key, return the entire hash
	return $self->{'INFO'} unless $key;

	# otherwise, return the value for the given key
	return $self->{'INFO'}{lc $key};
}

sub comment_tags {
	my $self = shift;

	my %keys = ();

	return grep { !$keys{$_}++ } @{$self->{'COMMENT_KEYS'}};
}

sub comment {
	my $self = shift;
	my $key = shift;

	# if the user supplied key does not exist, return undef
	return undef unless($self->{'COMMENTS'}{lc $key});

	return wantarray 
		? @{$self->{'COMMENTS'}{lc $key}}
		: $self->{'COMMENTS'}{lc $key}->[0];
}

sub path {
	my $self = shift;

	return $self->{'fileName'};
}

# "private" methods
sub _init {
	my $data = shift;

	# check the header to make sure this is actually an Ogg-Vorbis file
	$data->{'startInfoHeader'} = _check_header($data) || return undef;
	
	return 1;
}

sub _skip_id3_header {
	my $fh = shift;

	read $fh, my $buffer, 3;
	
	my $byte_count = 3;
	
	if ($buffer eq 'ID3') {

		while (read $fh, $buffer, 4096) {

			my $found;
			if (($found = index($buffer, OGGHEADERFLAG)) >= 0) {
				$byte_count += $found;
				seek $fh, $byte_count, 0;
				last;
			} else {
				$byte_count += 4096;
			}
		}

	} else {
		seek $fh, 0, 0;
	}

	return tell($fh);
}

sub _check_header {
	my $data = shift;

	my $fh = $data->{'fileHandle'};
	my $buffer;
	my $page_seg_count;

	# stores how far into the file we've read, so later reads into the file can
	# skip right past all of the header stuff

	my $byte_count = _skip_id3_header($fh);
	
	# Remember the start of the Ogg data
	$data->{startHeader} = $byte_count;

	# check that the first four bytes are 'OggS'
	read($fh, $buffer, 27);

	if (substr($buffer, 0, 4) ne OGGHEADERFLAG) {
		warn "This is not an Ogg bitstream (no OggS header).";
		return undef;
	}

	$byte_count += 4;

	# check the stream structure version (1 byte, should be 0x00)
	if (ord(substr($buffer, 4, 1)) != 0x00) {
		warn "This is not an Ogg bitstream (invalid structure version).";
		return undef;
	}

	$byte_count += 1;

	# check the header type flag 
	# This is a bitfield, so technically we should check all of the bits
	# that could potentially be set. However, the only value this should
	# possibly have at the beginning of a proper Ogg-Vorbis file is 0x02,
	# so we just check for that. If it's not that, we go on anyway, but
	# give a warning (this behavior may (should?) be modified in the future.
	if (ord(substr($buffer, 5, 1)) != 0x02) {
		warn "Invalid header type flag (trying to go ahead anyway).";
	}

	$byte_count += 1;

	# read the number of page segments
	$page_seg_count = ord(substr($buffer, 26, 1));
	$byte_count += 21;

	# read $page_seg_count bytes, then throw 'em out
	seek($fh, $page_seg_count, 1);
	$byte_count += $page_seg_count;

	# check packet type. Should be 0x01 (for indentification header)
	read($fh, $buffer, 7);
	if (ord(substr($buffer, 0, 1)) != 0x01) {
		warn "Wrong vorbis header type, giving up.";
		return undef;
	}

	$byte_count += 1;

	# check that the packet identifies itself as 'vorbis'
	if (substr($buffer, 1, 6) ne 'vorbis') {
		warn "This does not appear to be a vorbis stream, giving up.";
		return undef;
	}

	$byte_count += 6;

	# at this point, we assume the bitstream is valid
	return $byte_count;
}

sub _load_info {
	my $data = shift;

	my $start = $data->{'startInfoHeader'};
	my $fh    = $data->{'fileHandle'};

	my $byte_count = $start + 23;
	my %info = ();

	seek($fh, $start, 0);

	# read the vorbis version
	read($fh, my $buffer, 23);
	$info{'version'} = _decode_int(substr($buffer, 0, 4, ''));

	# read the number of audio channels
	$info{'channels'} = ord(substr($buffer, 0, 1, ''));

	# read the sample rate
	$info{'rate'} = _decode_int(substr($buffer, 0, 4, ''));

	# read the bitrate maximum
	$info{'bitrate_upper'} = _decode_int(substr($buffer, 0, 4, ''));

	# read the bitrate nominal
	$info{'bitrate_nominal'} = _decode_int(substr($buffer, 0, 4, ''));

	# read the bitrate minimal
	$info{'bitrate_lower'} = _decode_int(substr($buffer, 0, 4, ''));

	# read the blocksize_0 and blocksize_1
	# these are each 4 bit fields, whose actual value is 2 to the power
	# of the value of the field
	my $blocksize = substr($buffer, 0, 1, '');
	$info{'blocksize_0'} = 2 << ((ord($blocksize) & 0xF0) >> 4);
	$info{'blocksize_1'} = 2 << (ord($blocksize) & 0x0F);

	# read the framing_flag
	$info{'framing_flag'} = ord(substr($buffer, 0, 1, ''));

	# bitrate_window is -1 in the current version of vorbisfile
	$info{'bitrate_window'} = -1;

	$data->{'startCommentHeader'} = $byte_count;

	$data->{'INFO'} = \%info;
}

sub _load_comments {
	my $data = shift;

	my $fh    = $data->{'fileHandle'};
	my $start = $data->{'startHeader'};

	$data->{COMMENT_KEYS} = [];

	# Comment parsing code based on Image::ExifTool::Vorbis
	my $MAX_PACKETS = 2;
	my $done;
	my ($page, $packets, $streams) = (0,0,0,0);
	my ($buff, $flag, $stream, %val);

	seek $fh, $start, 0;

	while (1) {	
		if (!$done && read( $fh, $buff, 28 ) == 28) {
			# validate magic number
			unless ( $buff =~ /^OggS/ ) {
				warn "No comment header?";
				last;
			}

			$flag   = get8u(\$buff, 5);	# page flag
			$stream = get32u(\$buff, 14);	# stream serial number
			++$streams if $flag & 0x02;	# count start-of-stream pages
			++$packets unless $flag & 0x01; # keep track of packet count
		}
		else {
			# all done unless we have to process our last packet
			last unless %val;
			($stream) = sort keys %val;     # take a stream
			$flag = 0;                      # no continuation
			$done = 1;                      # flag for done reading
		}
		
		# can finally process previous packet from this stream
		# unless this is a continuation page
		if (defined $val{$stream} and not $flag & 0x01) {
			_process_comments( $data, \$val{$stream} );
			delete $val{$stream};
			# only read the first $MAX_PACKETS packets from each stream
			if ($packets > $MAX_PACKETS * $streams) {
				# all done (success!)
				last unless %val;
				# process remaining stream(s)
				next;
			}
		}

		# stop processing Ogg Vorbis if we have scanned enough packets
		last if $packets > $MAX_PACKETS * $streams and not %val;
		
		# continue processing the current page
		# page sequence number
		my $page_num = get32u(\$buff, 18);

		# number of segments
		my $nseg    = get8u(\$buff, 26);

		# calculate total data length
		my $data_len = get8u(\$buff, 27);
		
		if ($nseg) {
			read( $fh, $buff, $nseg-1 ) == $nseg-1 or last;
			my @segs = unpack('C*', $buff);
			# could check that all these (but the last) are 255...
			foreach (@segs) { $data_len += $_ }
		}

		if (defined $page) {
			if ($page == $page_num) {
				++$page;
			} else {
				warn "Missing page(s) in Ogg file\n";
				undef $page;
			}
		}
		
		# read page data
		read($fh, $buff, $data_len) == $data_len or last;

		if (defined $val{$stream}) {
			# add this continuation page
			$val{$stream} .= $buff;
		} elsif (not $flag & 0x01) {
			# ignore remaining pages of a continued packet
			# ignore the first page of any packet we aren't parsing
			if ($buff =~ /^(.)vorbis/s and ord($1) == 3) {
				# save this page, it has comments
				$val{$stream} = $buff;
			}
		}
		
		if (defined $val{$stream} and $flag & 0x04) {
			# process Ogg Vorbis packet now if end-of-stream bit is set
			_process_comments($data, \$val{$stream});
			delete $val{$stream};
		}
	}
	
	$data->{'INFO'}{offset} = tell $fh;
}

sub _process_comments {
	my ( $data, $data_pt ) = @_;
	
	my $pos = 7;
	my $end = length $$data_pt;
	
	my $num;
	my %comments;
	
	while (1) {
		last if $pos + 4 > $end;
		my $len = get32u($data_pt, $pos);
		last if $pos + 4 + $len > $end;
		my $start = $pos + 4;
		my $buff = substr($$data_pt, $start, $len);
		$pos = $start + $len;
		my ($tag, $val);
		if (defined $num) {
			$buff =~ /(.*?)=(.*)/s or last;
			($tag, $val) = ($1, $2);
		} else {
			$tag = 'vendor';
			$val = $buff;
			$num = ($pos + 4 < $end) ? get32u($data_pt, $pos) : 0;
			$pos += 4;
		}
		
		my $lctag = lc $tag;
		
		push @{$comments{$lctag}}, $val;
		push @{$data->{COMMENT_KEYS}}, $lctag;
		
		# all done if this was our last tag
		if ( !$num-- ) {
			$data->{COMMENTS} = \%comments;
			return 1;
		}
	}
	
	warn "format error in Vorbis comments\n";
	
	return 0;
}

sub get8u {
	return unpack( "x$_[1] C", ${$_[0]} );
}

sub get32u {
	return unpack( "x$_[1] V", ${$_[0]} );
}

sub _calculate_track_length {
	my $data = shift;

	my $fh = $data->{'fileHandle'};

	# The original author was doing something pretty lame, and was walking the
	# entire file to find the last granule_position. Instead, let's seek to
	# the end of the file - blocksize_0, and read from there.
	my $len = 0;

	# Bug 1155 - Seek further back to get the granule_position.
	# However, for short tracks, don't seek that far back.
	if (($data->{'filesize'} - $data->{'INFO'}{'offset'}) > ($data->{'INFO'}{'blocksize_0'} * 2)) {

		$len = $data->{'INFO'}{'blocksize_0'} * 2;
	} elsif ($data->{'filesize'} < $data->{'INFO'}{'blocksize_0'}) {
		$len = $data->{'filesize'};
	} else {
		$len = $data->{'INFO'}{'blocksize_0'};
	}

	if ($data->{'INFO'}{'blocksize_0'} == 0) {
		print "Ogg::Vorbis::Header::PurePerl:\n";
		warn "blocksize_0 is 0! Should be a power of 2! http://www.xiph.org/ogg/vorbis/doc/vorbis-spec-ref.html\n";
		return;
	}

	seek($fh, -$len, 2);

	my $buf = '';
	my $found_header = 0;
	my $block = $len;

	SEEK:
	while ($found_header == 0 && read($fh, $buf, $len)) {
		# search the last read $block bytes for Ogg header flag
		# the search is conducted backwards so that the last flag
		# is found first
		for (my $i = $block; $i >= 0; $i--) {
			if (substr($buf, $i, 4) eq OGGHEADERFLAG) {
				substr($buf, 0, ($i+4), '');
				$found_header = 1;
				last SEEK;
			}
		}

		# already read the whole file?
		last if $len == $data->{'filesize'};

		$len += $block;
		$len = $data->{'filesize'} if $len > $data->{'filesize'};

		seek($fh, -$len, 2);
	}

	unless ($found_header) {
		warn "Ogg::Vorbis::Header::PurePerl: Didn't find an ogg header - invalid file?\n";
		return;
	}

	# stream structure version - must be 0x00
	if (ord(substr($buf, 0, 1, '')) != 0x00) {
		warn "Ogg::Vorbis::Header::PurePerl: Invalid stream structure version: " . sprintf("%x", ord($buf));
		return;
 	}

 	# absolute granule position - this is what we need!
	substr($buf, 0, 1, '');

 	my $granule_position = _decode_int(substr($buf, 0, 8, ''));

	if ($granule_position && $data->{'INFO'}{'rate'}) {
		$data->{'INFO'}{'length'}          = int($granule_position / $data->{'INFO'}{'rate'});
		$data->{'INFO'}{'bitrate_average'} = sprintf( "%d", ( $data->{'filesize'} * 8 ) / $data->{'INFO'}{'length'} );
	} else {
		$data->{'INFO'}{'length'} = 0;
	}
}

sub _decode_int {
	my $bytes = shift;

	my $num_bytes = length($bytes);
	my $num = 0;
	my $mult = 1;

	for (my $i = 0; $i < $num_bytes; $i ++) {

		$num += ord(substr($bytes, 0, 1, '')) * $mult;
		$mult *= 256;
	}

	return $num;
}

1;

__END__

=head1 NAME

Ogg::Vorbis::Header::PurePerl - access Ogg Vorbis info and comment fields

=head1 SYNOPSIS

	use Ogg::Vorbis::Header::PurePerl;
	my $ogg = Ogg::Vorbis::Header::PurePerl->new("song.ogg");
	while (my ($k, $v) = each %{$ogg->info}) {
		print "$k: $v\n";
	}
	foreach my $com ($ogg->comment_tags) {
		print "$com: $_\n" foreach $ogg->comment($com);
	}

=head1 DESCRIPTION

This module is intended to be a drop in replacement for Ogg::Vorbis::Header,
implemented entirely in Perl.  It provides an object-oriented interface to
Ogg Vorbis information and comment fields.  (NOTE: This module currently 
supports only read operations).

Unlike Ogg::Vorbis::Header, this module will go ahead and fill in all of the
information fields as soon as you construct the object.

=head1 CONSTRUCTORS

=head2 C<new ($filename)>

Opens an Ogg Vorbis file, ensuring that it exists and is actually an
Ogg Vorbis stream.  This method does not actually read any of the
information or comment fields, and closes the file immediately. 

=head1 INSTANCE METHODS

=head2 C<info ([$key])>

Returns a hashref containing information about the Ogg Vorbis file from
the file's information header.  Hash fields are: version, channels, rate,
bitrate_upper, bitrate_nominal, bitrate_lower, bitrate_window, and length.
The bitrate_window value is not currently used by the vorbis codec, and 
will always be -1.  

The optional parameter, key, allows you to retrieve a single value from
the object's hash.  Returns C<undef> if the key is not found.

=head2 C<comment_tags ()>

Returns an array containing the key values for the comment fields. 
These values can then be passed to C<comment> to retrieve their values.

=head2 C<comment ($key)>

Returns an array of comment values associated with the given key.

=head2 C<add_comments ($key, $value, [$key, $value, ...])>

Unimplemented.

=head2 C<edit_comment ($key, $value, [$num])>

Unimplemented.

=head2 C<delete_comment ($key, [$num])>

Unimplemented.

=head2 C<clear_comments ([@keys])>

Unimplemented.

=head2 C<write_vorbis ()>

Unimplemented.

=head2 C<path ()>

Returns the path/filename of the file the object represents.

=head1 SEE ALSO

L<Ogg::Vorbis::Decoder> - module for decoding Ogg Vorbis files.
Requires a C compiler.

L<Ogg::Vorbis::Header> - another module for accessing Ogg Vorbis header info.

L<Ogg::Vorbis> - a perl interface to the
L<libvorbisfile|http://www.xiph.org/vorbis/doc/vorbisfile/> library,
for decoding and manipulating Vorbis audio streams.

=head1 REPOSITORY

L<https://github.com/dsully/perl-ogg-vorbis-header-pureperl>

=head1 AUTHOR

Andrew Molloy E<lt>amolloy@kaizolabs.comE<gt>

Dan Sully E<lt>daniel | at | cpan.orgE<gt>

=head1 COPYRIGHT

Copyright (c) 2003, Andrew Molloy.  All Rights Reserved.

Copyright (c) 2005-2009, Dan Sully.  All Rights Reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation; either version 2 of the License, or (at
your option) any later version.  A copy of this license is included
with this module (LICENSE.GPL).

=head1 SEE ALSO

L<Ogg::Vorbis::Header>, L<Ogg::Vorbis::Decoder>

=cut
