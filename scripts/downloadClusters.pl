#!/usr/bin/env perl 
#
# AUTHORS: Lee Katz <lkatz@cdc.gov> and Errol Strain <Errol.Strain@fda.hhs.gov>
# Run this script with --help for usage information.

use strict;
use warnings;
use Getopt::Long;
use Net::FTP;
use File::Basename qw/basename/;
use File::Temp qw/tempdir/;
use Data::Dumper;
use POSIX qw/strftime/;
use File::Copy qw/mv cp/;
use List::Util qw/min max/;

# Import local modules
use FindBin;
use lib "$FindBin::RealBin/../lib";
use Bio::Tree::Draw::Cladogram; # requires PostScript/TextBlock.pm in the lib dir
use Bio::TreeIO;
use PostScript::Simple;
use Time::Piece; # for parsing dates from Metadata.tsv
use Config::Simple;
#use Docopt;

local $0=basename($0);
sub logmsg { print STDERR "$0: @_\n"; }

exit(main());

sub main{
  my $settings={};
  GetOptions($settings,qw(help new-isolates report from=s to=s tempdir=s outdir=s set|results|resultsSet=s list maxTrees=i)) or die $!;
  $$settings{domain}||="ftp.ncbi.nlm.nih.gov";
  $$settings{tempdir}||=tempdir("$0.XXXXXX",TMPDIR=>1,CLEANUP=>1);
  $$settings{outdir}||="out";
  $$settings{set}||="Listeria";
  $$settings{maxTrees}||=0;

  # Parse the date parameters
  if($$settings{from}){
    $$settings{from}=parseDate($$settings{from});
  } else {
    $$settings{from}=parseDate(strftime("%m/%d/%Y",localtime(0)));
  }
  if($$settings{to}){
    $$settings{to}=parseDate($$settings{to});
  } else {
    $$settings{to}||=parseDate(strftime("%m/%d/%Y",localtime()));
  }

  if($$settings{list}){
    listSets($settings);
    return 0;
  }

  $$settings{remoteDir}||=$ARGV[0];

  if(!$$settings{remoteDir} || $$settings{help}){
    die usage($settings);
  }

  mkdir($$settings{tempdir}) if(!-e $$settings{tempdir});
  logmsg "Temporary directory is $$settings{tempdir}";
  logmsg "Downloading for $$settings{set}";
  mkdir($$settings{outdir}) if(!-e $$settings{outdir});

  downloadAll($$settings{remoteDir},$settings);
  my $metadata=readMetadata($settings);

  # Copies anything that passes the filters to the 
  # output directory.
  filterTrees($metadata,$settings);

  makeReport($metadata,$settings) if($$settings{report});

  return 0;
}

sub listSets{
  my($settings)=@_;

  my $ftp = Net::FTP->new($$settings{domain}, Debug => 0)
    or die "Cannot connect to $$settings{domain}: $@";
  $ftp->login("anonymous",'-anonymous@')
      or die "Cannot login ", $ftp->message;
  
  $ftp->cwd("//pathogen/Results")
    or die "Cannot change working directory ", $ftp->message;

  my @resultSets=$ftp->ls("");

  for(@resultSets){
    print $_."\n";
  }
  
  return \@resultSets;
}

sub downloadAll{
  my($remoteDir,$settings)=@_;

  my $ftp = Net::FTP->new($$settings{domain}, Debug => 0)
    or die "Cannot connect to $$settings{domain}: $@";
  $ftp->login("anonymous",'-anonymous@')
      or die "Cannot login ", $ftp->message;


  #Retrieve the metadata file
  logmsg "Retrieving metadata";
  mkdir "$$settings{tempdir}/Metadata";
  mkdir "$$settings{outdir}/Metadata";
  $ftp->cwd("//pathogen/Results/$$settings{set}/$remoteDir/Metadata/")
    or die "Cannot change working directory. It is possible that '$$settings{set}' ($remoteDir) does not exist. ", $ftp->message;
  my @metafiles = $ftp->ls("*.tsv");
  foreach(@metafiles) {
    $ftp->get($_,"$$settings{tempdir}/Metadata/$_")
      or die "get failed", $ftp->message;
  }

  #Retrieve SNP distances
  logmsg "Retrieving SNP distances";
  mkdir "$$settings{tempdir}/Clusters";
  mkdir "$$settings{outdir}/Clusters";
  $ftp->cwd("//pathogen/Results/$$settings{set}/$remoteDir/Clusters/")
    or die "Cannot change working directory ", $ftp->message;
  my @distfiles = $ftp->ls("*.SNP_distances.tsv");
  foreach(@distfiles) {
    $ftp->get($_,"$$settings{tempdir}/Clusters/$_")
      or die "get failed", $ftp->message;
  }
  # Retrieve the list of newest isolates, also in this directory
  my @newIsolateFiles=$ftp->ls("*.new_isolates.tsv");
  foreach(@newIsolateFiles){
    $ftp->get($_,"$$settings{tempdir}/Clusters/$_")
      or die "get failed", $ftp->message;
  }
  

  #Retrieve SNP trees
  logmsg "Retrieving trees";
  mkdir "$$settings{tempdir}/SNP_trees";
  mkdir "$$settings{outdir}/SNP_trees";
  $ftp->cwd("//pathogen/Results/$$settings{set}/$remoteDir/SNP_trees/")
    or die "Cannot change working directory ", $ftp->message;
  $ftp->ascii(); # download ascii encoding
  my @treefiles = $ftp->ls("*/*.newick");
  @treefiles=reverse(@treefiles); # assumed reverse order so that we get mostly new trees first
  logmsg scalar(@treefiles)." trees to download";
  for(my $i=0;$i<@treefiles;$i++){
    if($i % 100 == 0 && $i>0){
      logmsg "Finished downloading $i trees";
    }

    my $localfile="$$settings{tempdir}/SNP_trees/".basename($treefiles[$i]);

    # Don't download the file if you already have it or
    # if there wasn't even a tree in that directory (unlikely)
    if(-e $localfile){
      #logmsg "Found $localfile; skipping";
      next;
    }
    $ftp->get($treefiles[$i],$localfile)
      or die "get failed", $ftp->message;

    if($$settings{maxTrees} && $i >= $$settings{maxTrees}){
      last;
    }
  }

  $ftp->quit;

  return scalar(@treefiles);
}

sub readMetadata{
  my($settings)=@_;

  # Assume the metadata file is the only one in the temp directory
  my @metadataFiles=glob("$$settings{tempdir}/Metadata/*.metadata.tsv");

  my %metadata;
  for my $infile(@metadataFiles){
    # Make this file available to the user but read from the temp
    # file because the user would probably rather mess with
    # the output one (however unlikely).
    cp($infile,"$$settings{outdir}/Metadata/");

    open(my $metadataFh,"<",$infile) or die "ERROR: could not read $infile: $!";
    # Grab the header and turn it into an array
    my $header=<$metadataFh>; chomp($header);
    $header=~s/^\s+|^#|\s+$//g;  # trim whitespace and leading hash
    my @header=split(/\t/,$header);
    # Read the values in the file to associate them with the header(column) names
    while(my $line=<$metadataFh>){
      chomp($line);
      my @field=split(/\t/,$line);
      my %F;
      @F{@header}=@field; # get an index of header_name => field_value
      
      # Add onto the metadata hash.
      for(@header){
        # The ID of this hash will be the PDT identifier
        # because it is the same one used in the newick trees.
        # Because there could potentially be multiple metadata
        # spreadsheets, use the "equals if not blank"
        # operator to set each field. NOTE: this means that
        # in case of conflict, the first spreadsheet
        # that is read will take priority in setting the value.
        $metadata{$F{target_acc}}{$_}||=$F{$_};
      }
    }
    close $metadataFh;
  }

  return \%metadata;
}

sub filterTrees{
  my($metadata,$settings)=@_;

  # Index the list of new isolates if requested to 
  # filter by new isolates
  my %treeWithNewIsolate;
  if($$settings{'new-isolates'}){
    my $newisolatesFile=(glob("$$settings{tempdir}/Clusters/*.new_isolates.tsv"))[0];
    open(my $fh,"<",$newisolatesFile) or die "ERROR: cannot read $newisolatesFile: $!";
    my $header=<$fh>; chomp($header);
    my @header=split(/\t/,$header);
    while(<$fh>){
      chomp;
      my @F=split(/\t/,$_);
      my %F;
      @F{@header}=@F;
      $treeWithNewIsolate{$F{PDS_acc}}=\%F;
    }
    close $fh;
  }

  # Start the filtering process
  for my $tree(glob("$$settings{tempdir}/SNP_trees/*.newick")){
    # If the tree passes filters, then it gets moved here
    my $outtree="$$settings{outdir}/SNP_trees/".basename($tree);
    my $tree_passed_filters=1;  # innocent until guilty

    # Read in the tree and its leaves
    my $treeObj=Bio::TreeIO->new(-file=>$tree)->next_tree;
    my @sample=$treeObj->get_leaf_nodes(); # returns node objects

    # Determine whether this tree has any isolates in the 
    # time window that the user supplied
    my $is_in_timewindow=0; # assume false until proven true by >0 isolates
    for my $s(@sample){
      my $target_acc=$s->id;
      $target_acc=~s/^\'|\'$//g; # remove single quotes that might appear around taxa in the tree
      
      # Read in the date to an object, assuming the date is in Y-m-d format.
      # The best date to read is the collection date, but if not that, then
      # the target_creation_date is a good assumption (although sometimes not
      # accurate for DoC).
      my $dateToRead=$$metadata{$target_acc}{collection_date};
      $dateToRead=~s/^\s+|\s+//g; # whitespace trim so I don't have to worry about it below
      if($dateToRead=~/^$|^missing$|^null$|^0$/i){ # regex for blank or 'missing' or 0 or 'null'
        $dateToRead=$$metadata{$target_acc}{target_creation_date};
      }
      my $dateObj=parseDate($dateToRead);
      if($dateObj >= $$settings{from} && $dateObj <= $$settings{to}){
        $is_in_timewindow=1;
        last;
      }
    }

    # Delete the tree if it doesn't occur within the time window.
    if($is_in_timewindow){
      #logmsg "Tree passed: $tree";
    } else {
      #logmsg "Tree is not in the time window: $tree";
      $tree_passed_filters=0;
    }
    
    # Filter for new isolates only if requested
    if($$settings{'new-isolates'}){
      my $PDS_acc=basename($tree,".newick_tree.newick");
      if($treeWithNewIsolate{$PDS_acc}){
        
      } else {
        $tree_passed_filters=0;
      }
    }  

    # TODO any future filters?

    # If the tree passed all filters, then copy it over
    cp($tree,$outtree) or die "ERROR copying $tree to $tree:\n  $!";
  }

}

sub makeReport{
  my($metadata,$settings)=@_;
  
  my $postscript="$$settings{outdir}/report.ps";
  my $PDF="$$settings{outdir}/report.pdf";

  logmsg "Creating phylogeny images";
  mkdir "$$settings{outdir}/images";
  for my $tree(glob("$$settings{tempdir}/SNP_trees/*.newick")){
    my $eps="$$settings{outdir}/images/".basename($tree,'.newick').".eps";
    my $treeObj=Bio::TreeIO->new(-file=>$tree)->next_tree; # assume only one tree in the file
    #
    # Avoid a random divide by zero error in the cladogram module
    if($treeObj->get_root_node->height==0){
      #$treeObj->get_root_node->branch_length(1e-8);
      next;  # Skip; not sure what to do about this right now
    }

    addMetadataToTree($treeObj,$metadata,$settings);
    my $cladogram=Bio::Tree::Draw::Cladogram->new(
      -tree       => $treeObj,
      #-font       => "sans-serif",
      -size       => 12,
      -colors     => 1,
      -bootstrap  => 0,  # draw bootstraps?
      
      # no margins
      -top        => 0,  
      -right      => 0,
      -bottom     => 0,
      -left       => 0,
    );
    $cladogram->print(-file=>$eps);
  }

  # Make the full report
  my $p=new PostScript::Simple(
    papersize   => "Letter",
    colour      => 1,
    eps         => 0,
    units       => "pt",        # Must be in pt units instead of in because the tree eps files are in pt
    #coordorigin => "LeftTop",   # coordinate origin top-left
    #direction   => "RightDown", # direction for x-y coordinates
  );

  my $pageNumber=1;
  $p->newpage($pageNumber);
  $p->setcolour("black");
  $p->setfont("Times-Roman",32);
  $p->text({align=>"centre"},72*4,72*10,"Report from NCBI Pathogen Pipeline");
  $p->setfont("Times-Roman",24);
  $p->text({align=>"left"},72*4,72*9.5,"NCBI dataset: $$settings{set} ($$settings{remoteDir})");
  $p->text({align=>"left"},72*0.5,72*9.0,"Filters: from: $$settings{from}");
  $p->text({align=>"left"},72*0.5,72*8.5,"Filters: to: $$settings{to}");

  # Add a color legend
  $p->setcolour("black");
  $p->setlinewidth(1);
  $p->box(72*0.5,72*6,72*7.5,72*8);
  # First color: env/food
  $p->setcolour("red");
  $p->box({filled=>1},72*1,72*6.5,72*1.5,72*7);
  $p->setcolour("black");
  $p->text(72*2,72*6.5,"Environmental or Food");
  # Second color: clinical
  $p->setcolour("blue");
  $p->box({filled=>1},72*1,72*7.2,72*1.5,72*7.7);
  $p->setcolour("black");
  $p->text(72*2,72*7.2,"Clinical");

  # Footer for time generaged
  $p->setcolour("black");
  $p->setfont("Times-Roman",16);
  $p->text({align=>"centre"},72*4,72*1,"generated ".localtime()); 

  # Make a new page per tree
  #$p->setcolour(30,30,30);
  logmsg "Adding phylogeny images to larger report";
  for my $eps(glob("$$settings{outdir}/images/*.eps")){
    $p->newpage(++$pageNumber); # the PS module increments page numbers automatically starting with 1
    #$p->{direction}="RightDown";
    #$p->{coordorigin} = "LeftTop";   # coordinate origin bottom-left
    $p->setfont("Times-Roman",16);
    $p->setcolour("black");
    #logmsg "Writing to $eps";

    my $tree_acc=basename($eps,".newick_tree.eps");
    $p->text({align=>"centre"},4*72,10.5*72,$tree_acc);
    if($p->err()){
      die $p->err();
    }

    # Make URL to NCBI results directory
    # TODO when possible, switch the URL to the NCBI online Genome Workbench
    $p->setfont("Times-Roman",16);
    $p->text({align=>"left"},72*0.5,72*10,"ftp://ftp.ncbi.nlm.nih.gov/pathogen/Results/$$settings{set}/$$settings{remoteDir}/SNP_trees/$tree_acc");

    # Bio::Tree::Draw::Cladogram puts decimals into the width
    # but PostScript::Simple cannot understand decimals.
    # Therefore I have to find the bbox dimensions and write
    # them correctly to a new temporary file, then replace
    # the original with the temporary file.
    my @treeCoordinates;  #x1,y1,x2,y2
    open(my $epsFh,"<",$eps) or die "ERROR: could not read $eps: $!";
    open(my $epsNewFh,">","$eps.tmp") or die "ERROR: could not write to $eps.tmp: $!";
    while(my $line=<$epsFh>){
      if ($line=~/^\%\%BoundingBox:\s+(.+)\s*$/){
        my $dimensions=$1;
        @treeCoordinates=split(/\s+/,$dimensions);
        $_=int($_) for(@treeCoordinates);

        print $epsNewFh '%%BoundingBox: '.join(" ",@treeCoordinates)."\n";
      } else {
        print $epsNewFh $line;
      }
    }
    close $epsFh;

    die "ERROR: could not find bbox dimensions of $eps" if(!defined($treeCoordinates[3]));

    # Cement the new bbox dimensions into the file by
    # making a move (rename) command.
    system("mv $eps.tmp $eps");

    # Set up the direction of flow to bottom to top so that the
    # tree image doesn't get reversed and
    # set up pt because the image is in pt units.
    #$p->{direction}="RightUp";
    #$p->{coordorigin} = "LeftBottom";   # coordinate origin bottom-left

    # Make a 0.5 inch margin from the bottom left
    # 72 points per inch.
    $_=($_+=72*0.5) for(@treeCoordinates[0,2]); # shift X
    $_=($_+=72*0.5) for(@treeCoordinates[1,3]); # shift Y

    # Rescale if wider than the page or taller than the page.
    # Dimensions inside of the margin: 7.5" x 10"
    if($treeCoordinates[2] > 7.5*72 || $treeCoordinates[3] > 10*72){
      my $scale=min(7.5*72/$treeCoordinates[2], 10*72/$treeCoordinates[3]);
      $_ *= $scale for(@treeCoordinates);
    }

    $p->importepsfile($eps, @treeCoordinates);
    if($p->err()){
      die "ERROR with $eps:\n". $p->err();
    }
  }
  $p->output($postscript);
  logmsg "Wrote $pageNumber pages to $postscript";
  
  system("ps2pdf $postscript $PDF");
  if($?){
    logmsg "WARNING: could not use `ps2pdf` to convert $postscript to $PDF";
  } else {
    logmsg "Converted $postscript to $PDF";
  }
}
# A hacky way to parse a variety of dates
sub parseDate{
  my($date,$settings)=@_;

  return Time::Piece->strptime("12/31/1969","%m/%d/%Y") if($date=~/^\s*$/);

  # Don't die just because Time::Piece craps out
  my $timePiece;
  eval{
    if($date=~m|\d{1,2}/\d{1,2}/\d{2,4}|){
      $timePiece=Time::Piece->strptime($date,"%m/%d/%Y");
    } elsif($date=~m|\d{2,4}\-\d{1,2}\-\d{1,2}|){
      $timePiece=Time::Piece->strptime($date,"%Y-%m-%d");
    } else {

      # IF MMYYDD formats don't work, try just the year
      if($date=~/^\d{4}$/){
        $timePiece=Time::Piece->strptime($date,"%Y");
      } elsif($date=~/^(\d{4})/){ # just try first four digits of a number as a year
        $timePiece=Time::Piece->strptime($1,"%Y");
      }
        
    }
    return $timePiece;
  };
  return $timePiece if(defined $timePiece);

  logmsg "WARNING: I could not parse $date for dates. Using 12/31/1969.";
  return Time::Piece->strptime("12/31/1969","%m/%d/%Y");
}

sub addMetadataToTree{
  my($treeObj,$metadata,$settings)=@_;

  for my $node($treeObj->get_leaf_nodes){
    # remove leading and lagging quotes
    my $target_acc=$node->id;
    $target_acc=~s/^\'|\'$//g;
    #logmsg $node->id ." -> $target_acc";

    # rename the node
    $node->id($$metadata{$target_acc}{label});

    # add RGB color
    my($red,$blue,$green)=(0.1,0.1,0.1); # almost black by default
    if($$metadata{$target_acc}{attribute_package}=~/environmental|food/i){
      $blue=0.9;
      $red=0.3;
      $green=0.3;
    } elsif($$metadata{$target_acc}{attribute_package}=~/clinical|host/i){
      $blue=0.3;
      $red=0.9;
      $green=0.3;
    }
    #logmsg "added $red $green $blue to $target_acc";
    $node->add_tag_value("Rcolor",$red);
    $node->add_tag_value("Gcolor",$green);
    $node->add_tag_value("Bcolor",$blue);
  }
}
    
sub usage{
  my($settings)=@_;
  my $to=$$settings{to}->strftime("%m/%d/%Y");
  my $from=$$settings{from}->strftime("%m/%d/%Y");
  "$0: downloads NCBI Pathogen Detection Pipeline results
  Usage: $0 latest
    where 'latest' is the Pathogen Detection Pipeline 
    directory from which to retrieve results

  --tempdir     /tmp        Where temporary files go including
                            trees, metadata, etc
  --outdir      ./out       Where output files go
  --resultsSet  Listeria    Which NCBI results set to download
  --list                    List the options for results sets
  --report                  Create a report in outdir/report.pdf

  FILTERING
  --from        $from   Include trees with any isolates
                            as early as this date. Dates
                            can be in the format of either
                            YYYY-MM-DD or MM/DD/YYYY
  --to          $to   Include trees with isolates
                            as late as this date.
  --new-isolates            Only include trees that contain
                            newly uploaded isolates.
  --maxTrees    0           Download at most this many trees
  "
}
