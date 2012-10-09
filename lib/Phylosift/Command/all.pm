package Phylosift::Command::all;
use Phylosift -command;
use Phylosift::Settings;
use Phylosift::Phylosift;
use Carp;
use Cwd 'abs_path';
use Phylosift::Utilities qw(debug);
use Phylosift::Command::search;

sub description {
	return "phylosift all - run all steps for phylogenetic analysis of genomic or metagenomic sequence data";
}

sub abstract {
	return "run all steps for phylogenetic analysis of genomic or metagenomic sequence data";
}

sub usage_desc { "all %o <sequence file> [read 2 sequence file]" }

sub all_opts {
	my %allopt = (
		force =>       [ "force|f",      "Overwrites a previous Phylosift run with the same file name"],
		custom =>      [ "custom=s",     "Reads a custom marker list from a file otherwise use all the markers from the markers directory"],
		threads =>     [ "threads=i",    "Runs parallel portions using the specified number of processes (DEFAULT : 1)", {default => 1}],
		extended =>    [ "extended",     "Uses the extended set of markers", {default => 0}],
		paired =>      [ "paired",       "Looks for 2 input files (paired end sequencing) in FastQ format. Reversing the sequences for the second file listed and appending to the corresponding pair from the first file listed."],
		cont =>        [ "continue",     "Enables the pipeline to continue to subsequent steps when not using the 'all' mode"],
		updated =>     [ "updated",      "Use the set of updated markers instead of stock markers", {default => 1}],
		marker_url =>  [ "marker_url=s", "Phylosift will use markers available from the url provided"],
		output =>      [ "output=s",     "Specifies an output directory other than PStemp"],
		chunks =>      [ "chunks=i",     "Only run a set number of chunks"],
		chunk_size =>  [ "chunk_size=i", "Run so many sequences per chunk"],
		start_chunk => [ "start_chunk=i","Start processing on a particular chunk"],
	);
}

sub options {
	my %opts = all_opts();
	%opts = (%opts, Phylosift::Command::search::search_opts());
	%opts = (%opts, Phylosift::Command::align::align_opts());
	%opts = (%opts, Phylosift::Command::place::place_opts());
	%opts = (%opts, Phylosift::Command::summarize::summarize_opts());
	# all-specific options:
	$opts{keep_search} => [ "keep_search",  "Keeps the blastDir files (Default: Delete the blastDir files after every chunk)"],
	return values(%opts);
}

sub validate {
	my ($self, $opt, $args) = @_;

	# we need at least one argument beyond the options; die with that message
	# and the complete "usage" text describing switches, etc
	$self->usage_error("phylosift all requires exactly one or two file name arguments to run") unless @$args == 1 || @$args == 2;
}

sub set_ifdef {
	my $dest = $_[0]; 
	$$dest = $_[1] if defined $_[1];
}

sub load_opt {
	my %args = @_;
	my $opt = $args{opt};
	$Phylosift::Settings::file_dir = abs_path($opt->{output}) if defined($opt->{output});
	set_ifdef(\$Phylosift::Settings::paired, $opt->{paired});
	set_ifdef(\$Phylosift::Settings::custom, $opt->{custom});
	set_ifdef(\$Phylosift::Settings::force, $opt->{force});
	set_ifdef(\$Phylosift::Settings::continue, $opt->{continue});
	set_ifdef(\$Phylosift::Settings::threads, $opt->{threads});
	set_ifdef(\$Phylosift::Settings::simple, $opt->{simple});
	set_ifdef(\$Phylosift::Settings::isolate, $opt->{isolate});
	set_ifdef(\$Phylosift::Settings::besthit, $opt->{besthit});
	set_ifdef(\$Phylosift::Settings::coverage, $opt->{coverage});
	set_ifdef(\$Phylosift::Settings::updated, $opt->{updated});
	set_ifdef(\$Phylosift::Settings::marker_url, $opt->{marker_url});
	set_ifdef(\$Phylosift::Settings::extended, $opt->{extended});
	set_ifdef(\$Phylosift::Settings::configuration, $opt->{config});
	set_ifdef(\$Phylosift::Settings::keep_search, $opt->{keep_search});
	set_ifdef(\$Phylosift::Settings::disable_update_check, $opt->{disable_updates});
	set_ifdef(\$Phylosift::Settings::unique, $opt->{unique});
	set_ifdef(\$Phylosift::Settings::start_chunk, $opt->{start_chunk});
	set_ifdef(\$Phylosift::Settings::stdin, $opt->{stdin});
	set_ifdef(\$Phylosift::Settings::chunks, $opt->{chunks});
	set_ifdef(\$Phylosift::Settings::my_debug, $opt->{debug});
	set_ifdef(\$Phylosift::Settings::CHUNK_MAX_SEQS, $opt->{chunk_size});
	set_ifdef(\$Phylosift::Settings::bayes, $opt->{bayes});
	

	$Phylosift::Utilities::debuglevel = $Phylosift::Settings::my_debug || 0;
}

sub execute {
	my ($self, $opt, $args) = @_;
	load_opt(opt=>$opt);
	Phylosift::Command::sanity_check();

	my $ps = new Phylosift::Phylosift();
	$ps = $ps->initialize( mode => "all", file_1 => @$args[0], file_2 => @$args[1]);
	$ps->{"ARGV"} = \@ARGV;
	
	debug("FORCE: " . $Phylosift::Settings::force . "\n");
	debug("Continue : " . $Phylosift::Settings::continue . "\n");
	$ps->run( force=>$Phylosift::Settings::force, custom=>$Phylosift::Settings::custom, cont=>$Phylosift::Settings::continue );
}

1;