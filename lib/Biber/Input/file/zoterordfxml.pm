package Biber::Input::file::zoterordfxml;
use feature ':5.10';
#use 5.014001;
#use feature 'unicode_strings';
use strict;
use warnings;
use base 'Exporter';

use Carp;
use Biber::Constants;
use Biber::Entries;
use Biber::Entry;
use Biber::Entry::Names;
use Biber::Entry::Name;
use Biber::Sections;
use Biber::Section;
use Biber::Structure;
use Biber::Utils;
use Biber::Config;
use Digest::MD5 qw( md5_hex );
use File::Spec;
use Log::Log4perl qw(:no_extra_logdie_message);
use List::AllUtils qw( :all );
use XML::LibXML;
use XML::LibXML::Simple;
use Data::Dump qw(dump);

##### This is based on Zotero 2.0.9 #####

my $logger = Log::Log4perl::get_logger('main');
my $orig_key_order = {};

my %PREFICES = ('z'       => 'http://www.zotero.org/namespaces/export#',
                'foaf'    => 'http://xmlns.com/foaf/0.1/',
                'rdf'     => 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
                'dc'      => 'http://purl.org/dc/elements/1.1/',
                'dcterms' => 'http://purl.org/dc/terms/',
                'bib'     => 'http://purl.org/net/biblio#',
                'prism'   => 'http://prismstandard.org/namespaces/1.2/basic/',
                'vcard'   => 'http://nwalsh.com/rdf/vCard#',
                'vcard2'  => 'http://www.w3.org/2006/vcard/ns#');

# Handlers for field types
my %handlers = (
                'name'        => \&_name,
                'date'        => \&_date,
                'range'       => \&_range,
                'literal'     => \&_literal,
                'list'        => \&_list,
                'partof'      => \&_partof,
                'publisher'   => \&_publisher,
                'identifier'  => \&_identifier,
                'presentedat' => \&_presentedat,
                'subject'     => \&_subject
);

# Read driver config file
my $dcfxml = driver_config('zoterordfxml');

=head2 extract_entries

   Main data extraction routine.
   Accepts a data source identifier (filename in this case),
   preprocesses the file and then looks for the passed keys,
   creating entries when it finds them and passes out an
   array of keys it didn't find.

=cut

sub extract_entries {
  my ($biber, $filename, $keys) = @_;
  my $secnum = $biber->get_current_section;
  my $section = $biber->sections->get_section($secnum);
  my $bibentries = $section->bibentries;
  my @rkeys = @$keys;
  my $tf; # Up here so that the temp file has enough scope to survive until we've
          # used it
  $logger->trace("Entering extract_entries()");

  # If it's a remote data file, fetch it first
  if ($filename =~ m/\A(?:https?|ftp):\/\//xms) {
    $logger->info("Data source '$filename' is a remote .rdf - fetching ...");
    require LWP::Simple;
    require File::Temp;
    $tf = File::Temp->new(TEMPLATE => 'biber_remote_data_source_XXXXX',
                          DIR => $biber->biber_tempdir,
                          SUFFIX => '.rdf');
    unless (LWP::Simple::is_success(LWP::Simple::getstore($filename, $tf->filename))) {
      $logger->logdie ("Could not fetch file '$filename'");
    }
    $filename = $tf->filename;
  }
  else {
    # Need to get the filename even if using cache so we increment
    # the filename count for preambles at the bottom of this sub
    my $trying_filename = $filename;
    unless ($filename = locate_biber_file($filename)) {
      $logger->logdie("Cannot find file '$trying_filename'!")
    }
  }

  # Log that we found a data file
  $logger->info("Found zoterordfxml data file '$filename'");

  # Set up XML parser and namespaces
  my $parser = XML::LibXML->new();
  my $rdfxml = $parser->parse_file($filename)
    or $logger->logcroak("Can't parse file $filename");
  my $xpc = XML::LibXML::XPathContext->new($rdfxml);
  foreach my $ns (keys %PREFICES) {
    $xpc->registerNs($ns, $PREFICES{$ns});
  }

  if ($section->is_allkeys) {
    $logger->debug("All citekeys will be used for section '$secnum'");
    # Loop over all entries, creating objects
    foreach my $entry ($xpc->findnodes("/rdf:RDF/*")) {
      $logger->debug('Parsing Zotero RDF/XML entry object ' . $entry->nodePath);

      # If an entry has no key, ignore it and warn
      unless ($entry->hasAttribute('rdf:about')) {
        $logger->warn("Invalid or undefined RDF/XML ID in file '$filename', skipping ...");
        $biber->{warnings}++;
        next;
      }

      my $key = $entry->getAttribute('rdf:about');

      # sanitise the key for LaTeX
      $key =~ s/\A\#item_/item_/xms;

      # If we've already seen this key, ignore it and warn
      # Note the calls to lc() - we don't care about case when detecting duplicates
      if  (first {$_ eq lc($key)} @{$biber->get_everykey}) {
        $logger->warn("Duplicate entry key: '$key' in file '$filename', skipping ...");
        next;
      }
      else {
        $biber->add_everykey(lc($key));
      }

      # We do this as otherwise we have no way of determining the origing .bib entry order
      # We need this in order to do sorting=none + allkeys because in this case, there is no
      # "citeorder" because nothing is explicitly cited and so "citeorder" means .bib order
      push @{$orig_key_order->{$filename}}, $key;

      # We have to pass the datasource cased (and UTF-8ed) key to
      # create_entry() as this sub needs to know the datasource case of the
      # citation key so we can save it for output later after all the case-insensitive
      # work. If we lowercase before this, we lose this information.
      create_entry($biber, $key, $entry);
    }

    # if allkeys, push all bibdata keys into citekeys (if they are not already there)
    # We are using the special "orig_key_order" array which is used to deal with the
    # sitiation when sorting=non and allkeys is set. We need an array rather than the
    # keys from the bibentries hash because we need to preserver the original order of
    # the .bib as in this case the sorting sub "citeorder" means "bib order" as there are
    # no explicitly cited keys
    $section->add_citekeys(@{$orig_key_order->{$filename}});
    $logger->debug("Added all citekeys to section '$secnum': " . join(', ', $section->get_citekeys));
  }
  else {
    # loop over all keys we're looking for and create objects
    $logger->debug('Wanted keys: ' . join(', ', @$keys));
    foreach my $wanted_key (@$keys) {
      $logger->debug("Looking for key '$wanted_key' in Zotero RDF/XML file '$filename'");

      # Deal with messy Zotero auto-generated pseudo-keys
      my $temp_key = $wanted_key;
      $temp_key =~ s/\Aitem_/#item_/i;

      # Cache index keys are lower-cased. This next line effectively implements
      # case insensitive citekeys
      # FIXME NO IT DOESN'T. NEED TO SEARCH CASE_INSENSITIVE WITH XPATH 1.0
      if (my @entries = $xpc->findnodes("/rdf:RDF/*[\@rdf:about='" . lc($temp_key) . "']")) {
        # Check to see if there is more than one entry with this key and warn if so
        if ($#entries > 0) {
          $logger->warn("Found more than one entry for key '$wanted_key' in '$filename': " .
                       join(',', map {$_->getAttribute('rdf:about')} @entries) . ' - skipping duplicates ...');
          $biber->{warnings}++;
        }
        my $entry = $entries[0];

        my $key = $entry->getAttribute('rdf:about');
        $key =~ s/\A#item_/item_/i; # reverse of above

        $logger->debug("Found key '$wanted_key' in Zotero RDF/XML file '$filename'");
        $logger->debug('Parsing Zotero RDF/XML entry object ' . $entry->nodePath);
        # See comment above about the importance of the case of the key
        # passed to create_entry()
        create_entry($biber, $key, $entry);
        # found a key, remove it from the list of keys we want
        @rkeys = grep {$wanted_key ne $_} @rkeys;
      }
      $logger->debug('Wanted keys now: ' . join(', ', @rkeys));
    }
  }

  return @rkeys;
}


=head2 create_entry

   Create a Biber::Entry object from an entry found in a Zotero
   RDF/XML data source

=cut

sub create_entry {
  my ($biber, $dskey, $entry) = @_;
  my $secnum = $biber->get_current_section;
  my $section = $biber->sections->get_section($secnum);
  my $struc = Biber::Config->get_structure;
  my $bibentries = $section->bibentries;
  my $bibentry = new Biber::Entry;

  # Key casing is tricky. We need to note:
  #
  # Key matching is case-insensitive (BibTeX compat requirement)
  # In the .bbl, we should use the datasource case for the key
  # We don't care about the case of the citations themselves
  $bibentry->set_field('citekey', $dskey);

  # We also record the datasource key in original case in the section object
  # because there are certain places which need this
  # (for example shorthand list output) which need to output the key in the
  # right case but which have no access to entry objects
  $section->add_dskey($dskey);

  # Get a reference to the map option, if it exists
  my $user_map;
  if (defined(Biber::Config->getoption('map'))) {
    if (defined(Biber::Config->getoption('map')->{zoterordfxml})) {
      $user_map = Biber::Config->getoption('map')->{zoterordfxml};
    }
  }

  # Some entries like Series which are created for crossrefs don't have z:itemType
  my $itype = $entry->findvalue('./z:itemType') || $entry->nodeName;

  # We put all the fields we find modulo field aliases into the object.
  # Validation happens later and is not datasource dependent
FLOOP:  foreach my $f (uniq map {$_->nodeName()} $entry->findnodes('*')) {

    # FIELD MAPPING (ALIASES) DEFINED BY USER IN CONFIG FILE OR .bcf
    my $from;
    my $to;
    if ($user_map and
        my $field = firstval {lc($_) eq lc($f)} (keys %{$user_map->{field}},
                                                 keys %{$user_map->{globalfield}})) {

      # Enforce matching per-type mappings before global ones
      my $to_map;
      if (my $map = $user_map->{field}{$field}) {
        if (exists($map->{bmap_pertype})) {

          # Canonicalise pertype, can be a list Config::General is not clever enough
          # to do this, annoyingly
          if (ref($map->{bmap_pertype}) ne 'ARRAY') {
            $map->{bmap_pertype} = [ $map->{bmap_pertype} ];
          }

          # Now see if the per_type conditions match
          if (first {lc($_) eq lc($itype)} @{$map->{bmap_pertype}}) {
            $to_map = $user_map->{field}{$field}
          }
          else {
            $to_map = $user_map->{globalfield}{$field};
          }
        }
      }
      else {
        $to_map = $user_map->{globalfield}{$field};
      }

      # In case per_type doesn't match and there is no global map for this field
      next FLOOP unless defined($to_map);

      $from = $dcfxml->{fields}{field}{$f}; # handler information still comes from .dcf

      if (ref($to_map) eq 'HASH') { # complex field map
        $from = $dcfxml->{fields}{field}{lc($to_map->{bmap_target})};
        $to = lc($to_map->{bmap_target});

        # Deal with alsoset one->many maps
        while (my ($from_as, $to_as) = each %{$to_map->{alsoset}}) {
          if ($bibentry->field_exists(lc($from_as))) {
            if ($user_map->{bmap_overwrite}) {
              $biber->biber_warn($bibentry, "Overwriting existing field '$from_as' during aliasing of field '$from' to '$to' in entry '$dskey'");
            }
            else {
              $biber->biber_warn($bibentry, "Not overwriting existing field '$from_as' during aliasing of field '$from' to '$to' in entry '$dskey'");
              next;
            }
          }
          # Deal with special tokens
          given (lc($to_as)) {
            when ('bmap_origfield') {
              $bibentry->set_datafield(lc($from_as), $f);
            }
            when ('bmap_null') {
              $bibentry->del_datafield(lc($from_as));
              # 'future' delete in case it's not set yet
              $bibentry->block_datafield(lc($from_as));
            }
            default {
              $bibentry->set_datafield(lc($from_as), $to_as);
            }
          }
        }

        # map fields to targets
        if (lc($to_map->{bmap_target}) eq 'bmap_null') { # fields to ignore
          next FLOOP;
        }
      }
      else {                    # simple field map
        $to = lc($to_map);
        if ($to eq 'bmap_null') { # fields to ignore
          next FLOOP;
        }
        else {                  # normal simple field map
          $from = $dcfxml->{fields}{field}{$to};
        }
      }

      # Now run any defined handler
      &{$handlers{$from->{handler}}}($biber, $bibentry, $entry, $f, $to, $dskey);
    }
    # FIELD MAPPING (ALIASES) DEFINED BY DRIVER IN DRIVER CONFIG FILE
    elsif ($from = $dcfxml->{fields}{field}{$f}) { # ignore fields not in .dcf
      $to = $f; # By default, field to set internally is the same as data source
      # Redirect any alias
      if (my $aliases = $from->{alias}) { # complex aliases with alsoset clauses
        foreach my $alias (@$aliases) {
          if (my $t = $alias->{aliasfortype}) { # type-specific alias
            if (lc($t) eq lc($itype)) {
              my $a = $alias->{aliasof};
              $logger->debug("Found alias '$a' of field '$f' in entry '$dskey'");
              $from = $dcfxml->{fields}{field}{$a};
              $to = $a; # Field to set internally is the alias
              last;
            }
          }
          else {
            my $a = $alias->{aliasof}; # global alias
            $logger->debug("Found alias '$a' of field '$f' in entry '$dskey'");
            $from = $dcfxml->{fields}{field}{$a};
            $to = $a; # Field to set internally is the alias
          }

          # Deal with additional fields to split information into (one->many map)
          if (my $alsoset = $alias->{alsoset}) {
            my $val = $alsoset->{value} // $f; # defaults to original field name if no value
            $bibentry->set_datafield($alsoset->{target}, $val);
          }
        }
      }
      elsif (my $alias = $from->{aliasof}) { # simple alias
        $logger->debug("Found alias '$alias' of field '$f' in entry '$dskey'");
        $from = $dcfxml->{fields}{field}{$alias};
        $to = $alias; # Field to set internally is the alias
      }
      &{$handlers{$from->{handler}}}($biber, $bibentry, $entry, $f, $to, $dskey);
    }
  }

  # Set entrytype taking note of any user aliases or aliases for this datasource driver
  # This is here so that any field alsosets take precedence over fields in the data source

  # User aliases take precedence
  if (my $eta = firstval {lc($_) eq lc($itype)} keys %{$user_map->{entrytype}}) {
    my $from = lc($itype);
    my $to = $user_map->{entrytype}{$eta};
    if (ref($to) eq 'HASH') {   # complex entrytype map
      $bibentry->set_field('entrytype', lc($to->{bmap_target}));
      while (my ($from_as, $to_as) = each %{$to->{alsoset}}) { # any extra fields to set?
        if ($bibentry->field_exists(lc($from_as))) {
          if ($user_map->{bmap_overwrite}) {
            $biber->biber_warn($bibentry, "Overwriting existing field '$from_as' during aliasing of entrytype '$itype' to '" . lc($to->{bmap_target}) . "' in entry '$dskey'");
          }
          else {
            $biber->biber_warn($bibentry, "Not overwriting existing field '$from_as' during aliasing of entrytype '$itype' to '" . lc($to->{bmap_target}) . "' in entry '$dskey'");
            next;
          }
        }
        # Deal with special "BMAP_ORIGENTRYTYPE" token
        my $to_val = lc($to_as) eq 'bmap_origentrytype' ?
          $from : $to_as;
        $bibentry->set_datafield(lc($from_as), $to_val);
      }
    }
    else {                      # simple entrytype map
      $bibentry->set_field('entrytype', lc($to));
    }
  }
  # Driver aliases
  elsif (my $ealias = $dcfxml->{entrytypes}{entrytype}{$itype}) {
    $bibentry->set_field('entrytype', $ealias->{aliasof}{content});
    foreach my $alsoset (@{$ealias->{alsoset}}) {
      # drivers never overwrite existing fields
      if ($bibentry->field_exists(lc($alsoset->{target}))) {
        $biber->biber_warn($bibentry, "Not overwriting existing field '" . $alsoset->{target} . "' during aliasing of entrytype '$itype' to '" . lc($ealias->{aliasof}{content}) . "' in entry '$dskey'");
        next;
      }
      $bibentry->set_datafield($alsoset->{target}, $alsoset->{value});
    }
  }
  # No alias
  else {
    $bibentry->set_field('entrytype', $itype);
  }

  $bibentry->set_field('datatype', 'zoterordfxml');
  $bibentries->add_entry(lc($dskey), $bibentry);

  return $bibentry; # We need to return the entry here for _partof() below
}

# List fields
sub _list {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  $bibentry->set_datafield($to, [ $entry->findvalue("./$f") ]);
  return;
}

# literal fields
sub _literal {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  # Special case - libraryCatalog is used only if hasn't already been set
  # by LCC
  if ($f eq 'z:libraryCatalog') {
    return if $bibentry->get_field('library');
  }
  $bibentry->set_datafield($to, $entry->findvalue("./$f"));
  return;
}

# Range fields
sub _range {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  my $values_ref;
  my @values = split(/\s*,\s*/, $entry->findvalue("./$f"));
  # Here the "-–" contains two different chars even though they might
  # look the same in some fonts ...
  # If there is a range sep, then we set the end of the range even if it's null
  # If no  range sep, then the end of the range is undef
  foreach my $value (@values) {
    $value =~ m/\A\s*([^-–]+)([-–]*)([^-–]*)\s*\z/xms;
    my $end;
    if ($2) {
      $end = $3;
    }
    else {
      $end = undef;
    }
    push @$values_ref, [$1 || '', $end];
  }
  $bibentry->set_datafield($to, $values_ref);
  return;
}

# Date fields
sub _date {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  my $date = $entry->findvalue("./$f");
  # We are not validating dates here, just syntax parsing
    my $date_re = qr/(\d{4}) # year
                     (?:-(\d{2}))? # month
                     (?:-(\d{2}))? # day
                    /xms;
  if (my ($byear, $bmonth, $bday, $r, $eyear, $emonth, $eday) =
      $date =~ m|\A$date_re(/)?(?:$date_re)?\z|xms) {
    $bibentry->set_datafield('year',     $byear)      if $byear;
    $bibentry->set_datafield('month',    $bmonth)     if $bmonth;
    $bibentry->set_datafield('day',      $bday)       if $bday;
    $bibentry->set_datafield('endmonth', $emonth)     if $emonth;
    $bibentry->set_datafield('endday',   $eday)       if $eday;
    if ($r and $eyear) {        # normal range
      $bibentry->set_datafield('endyear', $eyear);
    }
    elsif ($r and not $eyear) { # open ended range - endyear is defined but empty
      $bibentry->set_datafield('endyear', '');
    }
  }
  else {
    $biber->biber_warn($bibentry, "Invalid format '$date' of date field '$f' in entry '$dskey' - ignoring");
  }
  return;
}

# Name fields
sub _name {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  my $names = new Biber::Entry::Names;
  foreach my $name ($entry->findnodes("./$f/rdf:Seq/rdf:li/foaf:Person")) {
    $names->add_name(parsename($name, $f));
  }
  $bibentry->set_datafield($to, $names);
  return;
}

# partof container
# This essentially is a bit like biblatex inheritance, but not as fine-grained
sub _partof {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  my $partof = $entry->findnodes("./$f")->get_node(1);
  my $itype = $entry->findvalue('./z:itemType') || $entry->nodeName;
  if ($partof->hasAttribute('rdf:resource')) { # remote ISSN resources aren't much use
    return;
  }
  # For 'webpage' types ('online' biblatex type), Zotero puts in a pointless
  # empty partof z:Website container
  if ($itype eq 'webpage') {
    return;
  }

  # create a dataonly entry for the partOf and add a crossref to it
  my $crkey = $dskey . '_' . md5_hex($dskey);
  $logger->debug("Creating a dataonly crossref '$crkey' for key '$dskey'");
  my $cref = create_entry($biber, $crkey, $partof->findnodes('*')->get_node(1));
  $cref->set_datafield('options', 'dataonly');
  Biber::Config->setblxoption('skiplab', 1, 'PER_ENTRY', $crkey);
  Biber::Config->setblxoption('skiplos', 1, 'PER_ENTRY', $crkey);
  $bibentry->set_datafield('crossref', $crkey);
  # crossrefs are a pain as we have to try to guess the
  # crossref type a bit. This corresponds to the relevant parts of the
  # default inheritance setup
  # This is a bit messy as we have to map from zotero entrytypes to biblatex data model types
  # because entrytypes are set after fields so bibaltex datatypes are not set yet.
  # The crossref entry isn't processed later so we have to set the real entrytype here.
  if ($cref->get_field('entrytype') =~ /\Abib:/) {
    given (lc($itype)) {
      when ('book')            { $cref->set_field('entrytype', 'mvbook') }
      when ('booksection')     { $cref->set_field('entrytype', 'book') }
      when ('conferencepaper') { $cref->set_field('entrytype', 'proceedings') }
      when ('presentation')    { $cref->set_field('entrytype', 'proceedings') }
      when ('journalarticle')  { $cref->set_field('entrytype', 'periodical') }
      when ('magazinearticle') { $cref->set_field('entrytype', 'periodical') }
      when ('newspaperarticle'){ $cref->set_field('entrytype', 'periodical') }
    }
  }
  return;
}

sub _publisher {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  if (my $org = $entry->findnodes("./$f/foaf:Organization")->get_node(1)) {
    # There is an address, set location.
    # Location is a list field in bibaltex, hence the array ref
    if (my $adr = $org->findnodes('./vcard:adr')->get_node(1)) {
      $bibentry->set_datafield('location', [ $adr->findvalue('./vcard:Address/vcard:locality') ]);
    }
    # set publisher
    # publisher is a list field in bibaltex, hence the array ref
    if (my $adr = $org->findnodes('./foaf:name')->get_node(1)) {
      $bibentry->set_datafield('publisher', [ $adr->textContent() ]);
    }
  }
  return;
}

sub _presentedat {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  if (my $conf = $entry->findnodes("./$f/bib:Conference")->get_node(1)) {
    $bibentry->set_datafield('eventtitle', $conf->findvalue('./dc:title'));
  }
  return;
}

sub _subject {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  if (my $lib = $entry->findnodes("./$f/dcterms:LCC/rdf:value")->get_node(1)) {
    # This overrides any z:libraryCatalog node
    $bibentry->set_datafield('library', $lib->textContent());
  }
  elsif (my @s = $entry->findnodes("./$f")) {
    my @kws;
    foreach my $s (@s) {
      push @kws, '{'.$s->textContent().'}';
    }
    $bibentry->set_datafield('keywords', join(',', @kws));
  }
  return;
}

sub _identifier {
  my ($biber, $bibentry, $entry, $f, $to, $dskey) = @_;
  if (my $url = $entry->findnodes("./$f/dcterms:URI/rdf:value")->get_node(1)) {
    $bibentry->set_datafield('url', $url->textContent());
  }
  else {
    foreach my $id_node ($entry->findnodes("./$f")) {
      if ($id_node->textContent() =~ m/\A(ISSN|ISBN|DOI)\s(.+)\z/) {
        $bibentry->set_datafield(lc($1), $2);
      }
    }
  }
  return;
}

=head2 parsename

    Given a name node, this function returns a Biber::Entry::Name object

    Returns an object which internally looks a bit like this:

    { firstname     => 'John',
      firstname_i   => 'J',
      middlename    => 'Fred',
      middlename_i  => 'F',
      lastname      => 'Doe',
      lastname_i    => 'D',
      prefix        => undef,
      prefix_i      => undef,
      suffix        => undef,
      suffix_i      => undef,
      namestring    => 'Doe, John Fred',
      nameinitstring => 'Doe_JF',

=cut

sub parsename {
  my ($node, $fieldname, $opts) = @_;
  $logger->debug('Parsing Zotero RDF/XML name object ' . $node->nodePath);

  my %nmap = ('surname'   => 'last',
              'givenname' => 'first');

  my %namec;

  foreach my $n ('surname', 'givenname') {
    if (my $nc = $node->findvalue("./foaf:$n")) {
      my $bn = $nmap{$n}; # convert to biblatex namepart name
      $namec{$bn} = $nc;
      $logger->debug("Found name component '$bn': $nc");
      $namec{"${bn}_i"} = [_gen_initials($nc)];
    }
  }

  # Only warn about lastnames since there should always be one
  $logger->warn("Couldn't determine Lastname for name node: " . $node->nodePath) unless exists($namec{last});

  my $namestring = '';

  # lastname
  if (my $l = $namec{last}) {
    $namestring .= "$l, ";
  }

  # firstname
  if (my $f = $namec{first}) {
    $namestring .= "$f";
  }

  # Remove any trailing comma and space if, e.g. missing firstname
  $namestring =~ s/,\s+\z//xms;

  # Construct $nameinitstring
  my $nameinitstr = '';
  $nameinitstr .= $namec{last} if exists($namec{last});
  $nameinitstr .= '_' . join('', @{$namec{first_i}}) if exists($namec{first});
  $nameinitstr =~ s/\s+/_/g;

  return Biber::Entry::Name->new(
    firstname       => $namec{first} // undef,
    firstname_i     => exists($namec{first}) ? $namec{first_i} : undef,
    lastname        => $namec{last} // undef,
    lastname_i      => exists($namec{last}) ? $namec{last_i} : undef,
    namestring      => $namestring,
    nameinitstring  => $nameinitstr
    );
}

# Passed an array ref of strings, returns an array ref of initials
sub _gen_initials {
  my @strings = @_;
  my @strings_out;
  foreach my $str (@strings) {
    # Deal with hyphenated name parts and normalise to a '-' character for easy
    # replacement with macro later
    if ($str =~ m/\p{Dash}/) {
      push @strings_out, join('-', _gen_initials(split(/\p{Dash}/, $str)));
    }
    else {
      my $chr = substr($str, 0, 1);
      # Keep diacritics with their following characters
      if ($chr =~ m/\p{Dia}/) {
        push @strings_out, substr($str, 0, 2);
      }
      else {
        push @strings_out, $chr;
      }
    }
  }
  return @strings_out;
}

1;

__END__

=pod

=encoding utf-8

=head1 NAME

Biber::Input::file::zoterordfxml - look in a Zotero RDFXML file for an entry and create it if found

=head1 DESCRIPTION

Provides the extract_entries() method to get entries from a biblatexml data source
and instantiate Biber::Entry objects for what it finds

=head1 AUTHOR

François Charette, C<< <firmicus at gmx.net> >>
Philip Kime C<< <philip at kime.org.uk> >>

=head1 BUGS

Please report any bugs or feature requests on our sourceforge tracker at
L<https://sourceforge.net/tracker2/?func=browse&group_id=228270>.

=head1 COPYRIGHT & LICENSE

Copyright 2009-2011 François Charette and Philip Kime, all rights reserved.

This module is free software.  You can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

This program is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=cut
