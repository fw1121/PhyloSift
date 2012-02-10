package Amphora2::FastSearch;
use warnings;
use strict;
use Cwd;
use Bio::SearchIO;
use Bio::SeqIO;
use Bio::SeqUtils;
use Carp;
use Amphora2::Amphora2;
use Amphora2::Utilities qw(:all);
use File::Basename;
use POSIX qw(ceil floor);
use constant FLANKING_LENGTH => 150;

=head1 NAME

Amphora2::FastSearch - Subroutines to perform fast sequence identity searches between reads and marker genes.
Currently uses either BLAST or RAPsearch.

=head1 VERSION

Version 0.01

=cut
our $VERSION = '0.01';

=head1 SYNOPSIS

Run blast on a list of families for a set of Reads
 
 input : Filename with marker list
         Filename for the reads file


 Output : For each marker, create a fasta file with all the reads and reference sequences.
          Storing the files in a directory called Blast_run

 Option : -clean removes the temporary files created to run the blast
          -threaded = #    Runs blast on multiple processors (I haven't see this use more than 1 processor even when specifying more)

=head1 EXPORT

A list of functions that can be exported.  You can delete this section
if you don't export anything, such as for a purely object-oriented module.

=head1 SUBROUTINES/METHODS

=head2 RunBlast

=cut
my $clean                 = 0;      #option set up, but not used for later
my $isolateMode           = 0;      # set to 1 if running on an isolate assembly instead of raw reads
my $bestHitsBitScoreRange = 30;     # all hits with a bit score within this amount of the best will be used
my $align_fraction        = 0.3;    # at least this amount of min[length(query),length(marker)] must align to be considered a hit
my $pair                  = 0;      #used if using paired FastQ files
my @markers;
my ( %hitsStart, %hitsEnd, %topscore, %hits, %markerHits, %markerNuc ) = ();
my $readsCore;
my $custom           = "";
my %marker_lookup    = ();
my %frames           = ();
my $reverseTranslate = 0;
my $blastdb_name     = "blastrep.faa";
my $blastp_params    = "-p blastp -e 0.1 -b 50000 -v 50000 -m 8";
my %markerLength;

sub RunSearch {
	my $self       = shift;
	my $custom     = shift;
	my $markersRef = shift;
	@markers    = @{$markersRef};
	%markerHits = ();
	my $position = rindex( $self->{"readsFile"}, "/" );
	$self->{"readsFile"} =~ m/(\w+)\.?(\w*)$/;
	$readsCore        = $1;
	$isolateMode      = $self->{"isolate"};
	$reverseTranslate = $self->{"reverseTranslate"};

	# check what kind of input was provided
	my ( $seqtype, $length, $format ) = Amphora2::Utilities::get_sequence_input_type( $self->{"readsFile"} );
	$self->{"dna"} = $seqtype eq "protein" ? 0 : 1;    # Is the input protein sequences?
	debug "Input type is $seqtype, $length, $format\n";

	# need to use BLAST for isolate mode, since RAP only handles very short reads
	# ensure databases and sequences are prepared for search
	debug "before rapPrepandclean\n";
	prepAndClean($self);
	if ( $self->{"readsFile_2"} ne "" ) {
		carp "Error, paired mode requires FastQ format input data" unless $format eq "fastq";
		debug "before fastqtoMergedFasta\n";
		fastqToMergedFasta($self);
	} elsif ( $format eq "fastq" ) {
		fastqToFasta( $self->{"readsFile"}, $self->{"blastDir"} . "/$readsCore.fasta" );
		$self->{"readsFile"} = $self->{"blastDir"} . "/$readsCore.fasta";
	}
	readMarkerLengths($self);

	# search reads/contigs against marker database
	my $resultsfile;
	my $searchtype = "blast";
	if ( $length eq "long" && $seqtype eq "protein" ) {
		$resultsfile = executeBlast( $self, $self->{"readsFile"} );
	} elsif ( $length eq "long" ) {
		$resultsfile = blastXoof_table( $self, $self->{"readsFile"} );
		$reverseTranslate = 1;
	} else {
		$searchtype  = "rap";
		$resultsfile = executeRap($self);
	}

	# parse the hits to marker genes
	my $hitsref;
	if ( $length eq "long" && $seqtype ne "protein" && ( !defined $self->{"isolate"} || $self->{"isolate"} != 1 ) ) {
		$hitsref = get_hits_contigs( $self, $resultsfile, $searchtype );
	} else {
		$hitsref = get_hits( $self, $resultsfile, $searchtype );
	}

	# write out sequence regions hitting marker genes to candidate files
	writeCandidates( $self, $hitsref );
	# delete files that we don't need anymore
#	cleanup($self);
	return $self;
}

sub cleanup {
	my $self = shift;
	`rm -f $self->{"blastDir"}/$readsCore.tabblastx`;
	`rm -f $self->{"blastDir"}/$readsCore.blastx`;
	`rm -f $self->{"blastDir"}/$readsCore.rapsearch.m8`;
	`rm -f $self->{"blastDir"}/$readsCore.rapsearch.aln`;
	`rm -f $self->{"blastDir"}/rep.faa`;
	`rm -f $self->{"blastDir"}/$blastdb_name`;
}

sub readMarkerLengths {
	my $self = shift;
	foreach my $marker (@markers) {
		$markerLength{$marker} = get_marker_length($marker);		
	}
}

=head2 blastXoof_table

=cut

sub blastXoof_table {
	my $self       = shift;
	my $query_file = shift;
	debug "INSIDE tabular OOF blastx\n";
`$Amphora2::Utilities::blastall -p blastx -i $query_file -e 0.1 -w 20 -b 50000 -v 50000 -d $self->{"blastDir"}/$blastdb_name -o $self->{"blastDir"}/$readsCore.tabblastx -m 8 -a $self->{"threads"} 2> /dev/null`;
	return $self->{"blastDir"} . "/$readsCore.tabblastx";
}

=head2 blastXoof_full

=cut

sub blastXoof_full {
	my $query_file = shift;
	my $self       = shift;
	debug "INSIDE full OOF blastx\n";
`$Amphora2::Utilities::blastall -p blastx -i $query_file -e 0.1 -w 20 -b 50000 -v 50000 -d $self->{"blastDir"}/$blastdb_name -o $self->{"blastDir"}/$readsCore.blastx -a $self->{"threads"} 2> /dev/null`;
	return $self;
}

=head2 translateFrame

=cut

sub translateFrame {
	my $id               = shift;
	my $seq              = shift;
	my $start            = shift;
	my $end              = shift;
	my $frame            = shift;
	my $marker           = shift;
	my $reverseTranslate = shift;
	my $returnSeq        = "";
	my $localseq         = substr( $seq, $start - 1, $end - $start + 1 );
	my $newseq           = Bio::LocatableSeq->new( -seq => $localseq, -id => 'temp' );
	$newseq = $newseq->revcom() if ( $frame < 0 );

	if ($reverseTranslate) {
		$id = Amphora2::Summarize::treeName($id);
		if ( exists $markerNuc{$marker} ) {
			$markerNuc{$marker} .= ">" . $id . "\n" . $newseq->seq . "\n";
		} else {
			$markerNuc{$marker} = ">" . $id . "\n" . $newseq->seq . "\n";
		}
	}
	$returnSeq = $newseq->translate();
	return $returnSeq->seq();
}

=head2 executeRap

=cut

sub executeRap {
	my $self = shift;
	if ( $self->{"readsFile"} !~ m/^\// ) {
		debug "Making sure rapsearch can find the readsfile\n";
		$self->{"readsFile"} = getcwd() . "/" . $self->{"readsFile"};
		debug "New readsFile " . $self->{"readsFile"} . "\n";
	}
	my $dbDir = "$Amphora2::Utilities::marker_dir/representatives";
	$dbDir = $self->{"blastDir"} if ( $custom ne "" );
	if ( !-e $self->{"blastDir"} . "/$readsCore.rapSearch.m8" ) {
		debug "INSIDE custom markers RAPSearch\n";
		`cd $self->{"blastDir"} ; $Amphora2::Utilities::rapSearch -q $self->{"readsFile"} -d rep -o $readsCore.rapSearch -v 20 -b 20 -e -1 -z $self->{"threads"}`;
	}
	return $self->{"blastDir"} . "/" . $readsCore . ".rapSearch.m8";
}

=head2 executeBlast

=cut

sub executeBlast {
	my $self       = shift;
	my $query_file = shift;
	my $dbDir      = "$Amphora2::Utilities::marker_dir/representatives";
	$dbDir = $self->{"blastDir"} if $custom ne "";
	debug "INSIDE BLAST\n";
	if ( !-e $self->{"blastDir"} . "/$readsCore.blastp" ) {
		`$Amphora2::Utilities::blastall $blastp_params -i $query_file -d $dbDir/$blastdb_name -o $self->{"blastDir"}/$readsCore.blastp -a $self->{"threads"}`;
	}
	return $self->{"blastDir"} . "/$readsCore.blastp";
}

=head2 fastqToFasta

Convert a FastQ file to FastA

=cut

sub fastqToFasta {
	my $infile  = shift;
	my $outfile = shift;
	my $count   = 0;
	debug "Reading $infile\n";
	open( FASTQ_1, $infile )     or croak("Couldn't open the FastQ file $infile\n");
	open( FASTA,   ">$outfile" ) or croak("Couldn't open $outfile for writing\n");
	while ( my $head1 = <FASTQ_1> ) {
		$head1 =~ s/^@/>/g if ( $count % 4 == 0 );
		print FASTA $head1 if ( $count % 4 < 2 );
		$count++;
	}
}

=head2 fastqToMergedFasta

    Writes a fastA file from 2 fastQ files from the Amphora2 object

=cut

sub fastqToMergedFasta {
	my $self = shift;
	if ( $self->{"readsFile_2"} ne "" ) {
		debug "FILENAME " . $self->{"fileName"} . "\n";
		return $self if ( -e $self->{"blastDir"} . "/$readsCore.fasta" );
		my %fastQ   = ();
		my $curr_ID = "";
		my $skip    = 0;
		debug "Reading " . $self->{"readsFile"} . "\n";
		open( FASTQ_1, $self->{"readsFile"} )   or croak "Couldn't open " . $self->{"readsFile"} . " in run_blast.pl reading the FastQ file\n";
		open( FASTQ_2, $self->{"readsFile_2"} ) or croak "Couldn't open " . $self->{"readsFile_2"} . " in run_blast.pl reading the FastQ file\n";
		debug "Writing " . $readsCore . ".fasta\n";
		open( FASTA, ">" . $self->{"blastDir"} . "/$readsCore.fasta" )
		  or croak "Couldn't open " . $self->{"blastDir"} . "/$readsCore.fasta for writing in run_blast.pl\n";

		while ( my $head1 = <FASTQ_1> ) {
			my $read1  = <FASTQ_1>;
			my $qhead1 = <FASTQ_1>;
			my $qval1  = <FASTQ_1>;
			my $head2  = <FASTQ_2>;
			my $read2  = <FASTQ_2>;
			my $qhead2 = <FASTQ_2>;
			my $qval2  = <FASTQ_2>;
			$head1 =~ s/^\@/\>/g;
			chomp($read1);
			chomp($read2);
			$read2 =~ tr/ACGTacgt/TGCAtgca/;
			$read2 = reverse($read2);
			print FASTA "$head1$read1$read2\n";
		}

		#pointing $readsFile to the newly created fastA file
		$self->{"readsFile"} = $self->{"blastDir"} . "/$readsCore.fasta";
	}
	return $self;
}

=head2 get_hits_contigs

parse the blast file

=cut

sub get_hits_contigs {
	my $self        = shift;
	my $hitfilename = shift;

	# key is a contig name
	# value is an array of arrays, each one has [marker,bit_score,left-end,right-end]
	my %contig_hits;
	my %contig_top_bitscore;
	my $max_hit_overlap = 10;
	open( blastIN, $hitfilename ) or carp( "Couldn't open " . $hitfilename . "\n" );
	while (<blastIN>) {

		# read a blast line
		next if ( $_ =~ /^#/ );
		chomp($_);
		my ( $query, $subject, $two, $three, $four, $five, $query_start, $query_end, $eight, $nine, $ten, $bitScore ) = split( /\t/, $_ );

		# get the marker name
		my @marker = split( /\_/, $subject );
		my $markerName = $marker[$#marker];

		# running on long reads or an assembly
		# allow each region of a sequence to have a top hit
		# do not allow overlap
		if ( defined( $contig_top_bitscore{$query}{$markerName} ) ) {
			my $i = 0;
			for ( ; $i < @{ $contig_hits{$query} } ; $i++ ) {
				my $prevhitref = $contig_hits{$query}->[$i];
				my @prevhit    = @$prevhitref;

				# is there enough overlap to consider these the same?
				# if so, take the new one if it has higher bitscore
				if (    $prevhit[2] < $prevhit[3]
					 && $query_start < $query_end
					 && $prevhit[2] < $query_end - $max_hit_overlap
					 && $query_start + $max_hit_overlap < $prevhit[3] )
				{

					#					print STDERR "Found overlap $query and $markerName, $query_start:$query_end\n";
					$contig_hits{$query}->[$i] = [ $markerName, $bitScore, $query_start, $query_end ] if ( $bitScore > $prevhit[1] );
					last;
				}

				# now check the same for reverse-strand hits
				if (    $prevhit[2] > $prevhit[3]
					 && $query_start > $query_end
					 && $prevhit[3] < $query_start - $max_hit_overlap
					 && $query_end + $max_hit_overlap < $prevhit[2] )
				{

					#					print STDERR "Found overlap $query and $markerName, $query_start:$query_end\n";
					$contig_hits{$query}->[$i] = [ $markerName, $bitScore, $query_start, $query_end ] if ( $bitScore > $prevhit[1] );
					last;
				}
			}
			if ( $i == @{ $contig_hits{$query} } ) {

				# no overlap was found, include this hit
				my @hitdata = [ $markerName, $bitScore, $query_start, $query_end ];
				push( @{ $contig_hits{$query} }, @hitdata );
			}
		} elsif ( !defined( $contig_top_bitscore{$query}{$markerName} ) ) {
			my @hitdata = [ $markerName, $bitScore, $query_start, $query_end ];
			push( @{ $contig_hits{$query} }, @hitdata );
			$contig_top_bitscore{$query}{$markerName} = $bitScore;
		}
	}
	return \%contig_hits;
}

=head2 get_hits

parse the blast file

=cut

sub get_hits {
	my $self        = shift;
	my $hitfilename = shift;
	my $searchtype  = shift;
	my %markerTopScores;
	my %topScore = ();
	my %contig_hits;
	open( blastIN, $hitfilename ) or carp( "Couldn't open " . $hitfilename . "\n" );
	while (<blastIN>) {
		chomp($_);
		next if ( $_ =~ /^#/ );
		my ( $query, $subject, $two, $three, $four, $five, $query_start, $query_end, $eight, $nine, $ten, $bitScore ) = split( /\t/, $_ );
		my $markerName = getMarkerName( $subject, $searchtype );

		#parse once to get the top score for each marker (if isolate is ON, parse again to check the bitscore ranges)
		if ( $isolateMode == 1 ) {

			# running on a genome assembly, allow only 1 hit per marker (TOP hit)
			if ( !defined( $markerTopScores{$markerName} ) || $markerTopScores{$markerName} < $bitScore ) {
				$markerTopScores{$markerName} = $bitScore;
			}
		} else {

			# running on short reads, just do one marker per read
			$topScore{$query} = 0 unless exists $topScore{$query};

			#only keep the top hit
			if ( $topScore{$query} <= $bitScore ) {
				$contig_hits{$query} = [ [ $markerName, $bitScore, $query_start, $query_end ] ];
				$topScore{$query} = $bitScore;
			}    #else do nothing
		}
	}
	close(blastIN);
	if ( $isolateMode == 1 ) {

		# reading the output a second to check the bitscore ranges from the top score
		open( blastIN, $hitfilename ) or die "Couldn't open $hitfilename\n";

		# running on a genome assembly, allow more than one marker per sequence
		# require all hits to the marker to have bit score within some range of the top hit
		while (<blastIN>) {
			chomp($_);
			next if ( $_ =~ /^#/ );
			my ( $query, $subject, $two, $three, $four, $five, $query_start, $query_end, $eight, $nine, $ten, $bitScore ) = split( /\t/, $_ );
			my $markerName = getMarkerName( $subject, $searchtype );
			my @hitdata = [ $markerName, $bitScore, $query_start, $query_end ];
			if ( !$self->{"besthit"} && $markerTopScores{$markerName} < $bitScore + $bestHitsBitScoreRange ) {
				push( @{ $contig_hits{$query} }, @hitdata );
			} elsif ( $markerTopScores{$markerName} <= $bitScore ) {
				push( @{ $contig_hits{$query} }, @hitdata );
			}
		}
		close(blastIN);
	}
	return \%contig_hits;
}

=head2 getMarkerName

Extracts a marker gene name from a blast or rapsearch subject sequence name

=cut

sub getMarkerName {
	my $subject    = shift;
	my $searchtype = shift;
	my $markerName = "";
	if ( $searchtype eq "blast" ) {
		my @marker = split( /\_/, $subject );
		$markerName = $marker[$#marker];
	} else {
		my @marker = split( /\_\_/, $subject );
		$markerName = $marker[0];
	}
#	debug "Using marker name $markerName";
	return $markerName;
}

=head2 writeCandidates

write out results

=cut

sub writeCandidates {
	my $self          = shift;
	my $contigHitsRef = shift;
	my %contig_hits   = %$contigHitsRef;
	debug "ReadsFile:  $self->{\"readsFile\"}" . "\n";
	my $seqin = new Bio::SeqIO( '-file' => $self->{"readsFile"} );
	while ( my $seq = $seqin->next_seq ) {

		# skip this one if there are no hits
		next unless ( exists $contig_hits{ $seq->id } );
		for ( my $i = 0 ; $i < @{ $contig_hits{ $seq->id } } ; $i++ ) {
			my $curhitref = $contig_hits{ $seq->id }->[$i];
			my @curhit    = @$curhitref;
			my $markerHit = $curhit[0];
			my $start     = $curhit[2];
			my $end       = $curhit[3];
			( $start, $end ) = ( $end, $start ) if ( $start > $end );    # swap if start bigger than end

			# check to ensure hit covers enough of the marker
			# TODO: make this smarter about boundaries, e.g. allow a smaller fraction to hit
			# if it looks like the query seq goes off the marker boundary
			if(!defined($markerHit)||!defined($markerLength{$markerHit})){
				print "markerHit is $markerHit\n";
				print $markerLength{$markerHit}."\n";
			}
			my $min_len = $markerLength{$markerHit} < $seq->length ? $markerLength{$markerHit} : $seq->length;
			next unless ( ( $end - $start ) / $min_len >= $align_fraction );
			$start -= FLANKING_LENGTH;
			$end += FLANKING_LENGTH;

			# ensure flanking region is a multiple of 3 to avoid breaking frame in DNA
			$start = abs($start) % 3 + 1 if ( $start < 0 );
			my $seqLength = length( $seq->seq );
			$end = $end - ceil( ( $end - $seqLength ) / 3 ) * 3 if ( $end >= $seqLength );
			my $newSeq = substr( $seq->seq, $start, $end - $start );

			#if we're working from DNA then need to translate to protein
			if ( $self->{"dna"} ) {

				# compute the frame as modulo 3 of start site, reverse strand if end < start
				my $frame = $curhit[2] % 3 + 1;
				$frame *= -1 if ( $curhit[2] > $curhit[3] );
				my $seqlen = abs( $curhit[2] - $curhit[3] ) + 1;

				# check length again in AA units
				$min_len = $markerLength{$markerHit} < $seq->length / 3 ? $markerLength{$markerHit} : $seq->length / 3;
				next unless ( ( $seqlen / 3 ) / $min_len >= $align_fraction );
				if ( $seqlen % 3 == 0 ) {
					$newSeq = translateFrame( $seq->id, $seq->seq, $start, $end, $frame, $markerHit, $self->{"dna"} );
					$newSeq =~ s/\*/X/g;    # bioperl uses * for stop codons but we want to give X to hmmer later
				} else {
					warn "Error, alignment length not multiple of 3!  FIXME: need to pull frameshift from full blastx\n";
				}
			}
			$markerHits{$markerHit} = "" unless defined( $markerHits{$markerHit} );
			$markerHits{$markerHit} .= ">" . $seq->id . "\n" . $newSeq . "\n";

			#			$markerHits{$markerHit} .= ">".$seq->id.":$start-$end\n".$newSeq."\n";
		}
	}

	#write the read+ref_seqs for each markers in the list
	foreach my $marker ( keys %markerHits ) {

		#writing the hits to the candidate file
		open( fileOUT, ">" . $self->{"blastDir"} . "/$marker.candidate" ) or die " Couldn't open " . $self->{"blastDir"} . "/$marker.candidate for writing\n";
		print fileOUT $markerHits{$marker};
		close(fileOUT);
		if ( $self->{"dna"} ) {
			open( fileOUT, ">" . $self->{"blastDir"} . "/$marker.candidate.ffn" )
			  or die " Couldn't open " . $self->{"blastDir"} . "/$marker.candidate.ffn for writing\n";
			print fileOUT $markerNuc{$marker} if defined( $markerNuc{$marker} );
			close(fileOUT);
		}
	}
}

=head2 prepAndClean

=item *

Checks if the directories needed for the blast run and parsing exist
Removes previous blast runs data if they are still in the directories
Generates the blastable database using the marker representatives

=back

=cut

sub prepAndClean {
	my $self = shift;
	debug "prepclean MARKERS @markers\nTESTING\n ";
	`mkdir $self->{"tempDir"}` unless ( -e $self->{"tempDir"} );

	#create a directory for the Reads file being processed.
	`mkdir $self->{"fileDir"}`  unless ( -e $self->{"fileDir"} );
	`mkdir $self->{"blastDir"}` unless ( -e $self->{"blastDir"} );

	#when using the default marker package
	debug "Using the standard marker package\n";
	
	# use alignments to make an unaligned fasta database containing everything
	# strip gaps from the alignments
	open(DBOUT, ">".$self->{"blastDir"}."/$blastdb_name");
	foreach my $marker (@markers) {
		my $marker_aln = Amphora2::Utilities::get_marker_aln_file($self, $marker);
		open(INALN, "$Amphora2::Utilities::marker_dir/$marker_aln");
		while(my $line=<INALN>){
			if($line =~ /^>(.+)/){
				print DBOUT "\n>$marker"."__$1\n";
			}else{
				$line =~ s/[-\.\n\r]//g;
				$line =~ tr/a-z/A-Z/;
				print DBOUT $line;
			}
		}
	}
	print DBOUT "\n";
	close DBOUT;	# be sure to flush I/O
	# make a blast database
	`$Amphora2::Utilities::formatdb -i $self->{"blastDir"}/$blastdb_name -o F -p T -t RepDB`;
	`cd $self->{"blastDir"} ; mv $blastdb_name rep.faa`;
	# make a rapsearch database
	`cd $self->{"blastDir"} ; $Amphora2::Utilities::preRapSearch -d rep.faa -n rep`;

	return $self;
}

=head1 AUTHOR

Aaron Darling, C<< <aarondarling at ucdavis.edu> >>
Guillaume Jospin, C<< <gjospin at ucdavis.edu> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-amphora2-amphora2 at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Amphora2-Amphora2>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Amphora2::blast


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Amphora2-Amphora2>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Amphora2-Amphora2>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Amphora2-Amphora2>

=item * Search CPAN

L<http://search.cpan.org/dist/Amphora2-Amphora2/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Aaron Darling and Guillaume Jospin.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut
1;    # End of Amphora2::blast.pm
