package Phylosift::Command::build_marker;
use Phylosift -command;
use Phylosift::Settings;
use Phylosift::Phylosift;
use Phylosift::MarkerBuild;
use Carp;
use Phylosift::Utilities qw(debug);

sub description {
	return "phylosift build_marker - add a new marker the reference database based on a sequence alignment";
}

sub abstract {
	return "add a new marker the reference database based on a sequence alignment";
}

sub usage_desc { "build_marker %o" }

sub options {
	return (
		[ "force|f",        "Overwrites a previous Phylosift run with the same file name"],
		[ "alignment=s",    "A multiple sequence alignment of the gene family"],
		[ "update-only",    "Generate an updated marker only, no new HMM"],
		[ "reps_pd=i",      "Specify the minimum divergence between representative sequences", { default => 0.1 }], 
		[ "tree_pd=i",      "Specify the minimum phylogenetic diversity in the reference tree", { default => 0.1 }],
		[ "taxonmap=s",     "A file containing a mapping of sequence names to taxon IDs"],
	);
}

sub validate {
	my ($self, $opt, $args) = @_;
	
	$self->usage_error("build_marker requires an alignment") unless defined $opt->{alignment};
}

sub load_opt {
	my %args = @_;
	my $opt = $args{opt};
	$Phylosift::Settings::force = $opt->{force};
	$Phylosift::Settings::configuration = $opt->{config};
	$Phylosift::Settings::keep_search = $opt->{keep_search};
	$Phylosift::Settings::disable_update_check = $opt->{disable_updates};
	$Phylosift::Settings::my_debug = $opt->{debug};

	$Phylosift::Utilities::debuglevel = $Phylosift::Settings::my_debug || 0;	
}

sub execute {
	my ($self, $opt, $args) = @_;
	load_opt{opt=>$opt};
	Phylosift::Command::sanity_check();

	my $ps = new Phylosift::Phylosift();
	Phylosift::MarkerBuild::build_marker(self=>$ps, opt=>$opt, alignment=>$opt->{alignment}, force=>$opt->{force}, cutoff=>$opt->{reps_pd}, mapping=>$opt->{taxonmap});

}

1;