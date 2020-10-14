package Biber::Output::bibtex;
use v5.24;
use strict;
use warnings;
use parent qw(Biber::Output::base);

use Biber::Annotation;
use Biber::Config;
use Biber::Constants;
use Biber::Utils;
use List::AllUtils qw( :all );
use Encode;
use IO::File;
use Log::Log4perl qw( :no_extra_logdie_message );
use Scalar::Util qw(looks_like_number);
use Text::Wrap;
$Text::Wrap::columns = 80;
use Unicode::Normalize;
my $logger = Log::Log4perl::get_logger('main');

=encoding utf-8

=head1 NAME

Biber::Output::bibtex - class for bibtex output

=cut


=head2 set_output_target_file

    Set the output target file of a Biber::Output::bibtex object
    A convenience around set_output_target so we can keep track of the
    filename

=cut

sub set_output_target_file {
  my $self = shift;
  my $outfile = shift;
  $self->{output_target_file} = $outfile;
  return undef;
}

=head2 set_output_comment

  Set the output for a comment

=cut

sub set_output_comment {
  my $self = shift;
  my $comment = shift;
  my $acc = '';

  # Make the right casing function
  my $outmap;

  if (Biber::Config->getoption('output_fieldcase') eq 'upper') {
    $outmap = sub {my $f = shift; uc($CONFIG_OUTPUT_FIELDREPLACE{$f} // $f)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'lower') {
    $outmap = sub {my $f = shift; lc($CONFIG_OUTPUT_FIELDREPLACE{$f} // $f)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'title') {
    $outmap = sub {my $f = shift; ucfirst($CONFIG_OUTPUT_FIELDREPLACE{$f} // $f)};
  }

  $acc .= '@';
  $acc .= $outmap->('comment');
  $acc .= "{$comment}\n";

  push $self->{output_data}{COMMENTS}->@*, $acc;
  return;
}

=head2 set_output_macro

  Set the output for a macro

=cut

sub set_output_macro {
  my $self = shift;
  my $macro = shift;
  my $acc = '';

  # Only output used macros unless we are asked to output all
  unless (Biber::Config->getoption('output_all_macros')) {
    return unless $USEDSTRINGS{$macro};
  }

  # Make the right casing function
  my $casing;

  if (Biber::Config->getoption('output_fieldcase') eq 'upper') {
    $casing = sub {uc(shift)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'lower') {
    $casing = sub {lc(shift)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'title') {
    $casing = sub {ucfirst(shift)};
  }

  $acc .= '@';
  $acc .= $casing->('string');
  $acc .= '{' . $casing->($macro) . ' = "' . Text::BibTeX::macro_text($macro) . "\"}\n";

  push $self->{output_data}{MACROS}->@*, $acc;
  return;
}

=head2 set_output_entry

  Set the output for an entry

=cut

sub set_output_entry {
  my $self = shift;
  my $be = shift; # Biber::Entry object
  my $bee = $be->get_field('entrytype');
  my $section = shift; # Section object the entry occurs in
  my $dm = shift; # Data Model object
  my $dmh = $dm->{helpers};
  my $acc = '';
  my $secnum = $section->number;
  my $key = $be->get_field('citekey');
  my $omssep = $CONFIG_META_MARKERS{outputmssep};

  # Make the right casing/output mapping function
  my $outmap;
  if (Biber::Config->getoption('output_fieldcase') eq 'upper') {
    $outmap = sub {my $f = shift; uc($CONFIG_OUTPUT_FIELDREPLACE{$f} // $f)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'lower') {
    $outmap = sub {my $f = shift; lc($CONFIG_OUTPUT_FIELDREPLACE{$f} // $f)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'title') {
    $outmap = sub {my $f = shift; ucfirst($CONFIG_OUTPUT_FIELDREPLACE{$f} // $f)};
  }

  $acc .= '@';
  $acc .= $outmap->($bee);
  $acc .=  "\{$key,\n";

  # hash accumulator so we can gather all the data before formatting so that things like
  # $max_field_len can be calculated
  my %acc;

  # IDs
  if (my $val = $be->get_field('ids')) {
    $acc{$outmap->('ids')} = join(',', $val->get_items->@*);
  }

  # Name fields
  my $tonamesub = 'name_to_bibtex';
  if (Biber::Config->getoption('output_xname')) {
    $tonamesub = 'name_to_xname';
  }

  foreach my $namefield ($dmh->{namelists}->@*) {
    foreach my $alts ($be->get_alternates_for_field($namefield)->@*) {
      my $names = $alts->{val};
      my $form  = $alts->{form} // '';
      my $lang  = $alts->{lang} // '';

      $form = ($form eq 'default' or not $form) ? '' : "$omssep$form";
      $lang = ($lang eq Biber::Config->get_mslang($key) or not $lang) ? '' : "$omssep$lang";

      # XDATA is special
      unless (Biber::Config->getoption('output_resolve_xdata')) { # already resolved
        if (my $xdata = $names->get_xdata) {
          $acc{$outmap->($namefield) . lc($form) . lc($lang)} = xdatarefout($xdata);
          next;
        }
      }

      my $namesep = Biber::Config->getoption('output_namesep');
      my @namelist;

      # Namelist scope useprefix
      if (defined($names->get_useprefix)) {# could be 0
        push @namelist, 'useprefix=' . map_boolean('useprefix', $names->get_useprefix, 'tostring');
      }

      # Namelist scope sortingnamekeytemplatename
      if (my $snks = $names->get_sortingnamekeytemplatename) {
        push @namelist, "sortingnamekeytemplatename=$snks";
      }

      # Now add all names to accumulator
      foreach my $name ($names->names->@*) {

        # XDATA is special
        unless (Biber::Config->getoption('output_resolve_xdata')) {
          if (my $xdata = $name->get_xdata) {
            push @namelist, xdatarefout($xdata);
            next;
          }
        }

        push @namelist, $name->$tonamesub;
      }

      $acc{$outmap->($namefield) . lc($form) . lc($lang)} = join(" $namesep ", @namelist);

      # Deal with morenames
      if ($names->get_morenames) {
        $acc{$outmap->($namefield) . lc($form) . lc($lang)} .= " $namesep others";
      }
    }
  }

  # List fields and verbatim list fields
  foreach my $listfield ($dmh->{lists}->@*, $dmh->{vlists}->@*) {
    foreach my $alts ($be->get_alternates_for_field($listfield)->@*) {
      my $list = $alts->{val};
      my $form  = $alts->{form} // '';
      my $lang  = $alts->{lang} // '';

      $form = ($form eq 'default' or not $form) ? '' : "$omssep$form";
      $lang = ($lang eq Biber::Config->get_mslang($key) or not $lang) ? '' : "$omssep$lang";

      my $listsep = Biber::Config->getoption('output_listsep');
      my @plainlist;
      foreach my $item ($list->get_items->@*) {
        unless (Biber::Config->getoption('output_resolve_xdata')) {
          my $xd = xdatarefcheck($item);
          $item = $xd // $item;
        }
        push @plainlist, $item;
      }
      $acc{$outmap->($listfield) . lc($form) . lc($lang)} = join(" $listsep ", @plainlist);
    }
  }

  # Per-entry options
  my @entryoptions;
  foreach my $opt (Biber::Config->getblxentryoptions($secnum, $key)) {
    push @entryoptions, $opt . '=' . Biber::Config->getblxoption($secnum, $opt, undef, $key);
  }
  $acc{$outmap->('options')} = join(',', @entryoptions) if @entryoptions;

  # Date fields
  foreach my $d ($dmh->{datefields}->@*) {
    $d =~ s/date$//;
    next unless $be->get_field("${d}year");

    # Output legacy dates for YEAR/MONTH if requested
    if (not $d and Biber::Config->getoption('output_legacy_dates')) {
      if (my $val = $be->get_field('year')) {
        if (not $be->get_field('day') and
            not $be->get_field('endyear')) {
          $acc{$outmap->('year')} = $val;
          if (my $mval = $be->get_field('month')) {
            if (Biber::Config->getoption('nostdmacros')) {
              $acc{$outmap->('month')} = $mval;
            }
            else {
              my %RMONTHS = reverse %MONTHS;
              $acc{$outmap->('month')} = $RMONTHS{$mval};
            }
          }
          next;
        }
        else {
          biber_warn("Date in entry '$key' has DAY or ENDYEAR, cannot be output in legacy format.");
        }
      }
    }

    $acc{$outmap->("${d}date")} = construct_datetime($be, $d);
  }

  # If CROSSREF and XDATA have been resolved, don't output them
  if (Biber::Config->getoption('output_resolve_crossrefs')) {
    if ($be->get_field('crossref')) {
      $be->del_field('crossref');
    }
  }
  if (Biber::Config->getoption('output_resolve_xdata')) {
    if ($be->get_field('xdata')) {
      $be->del_field('xdata');
    }
  }

  # Standard fields
  foreach my $field ($dmh->{fields}->@*) {
    foreach my $alts ($be->get_alternates_for_field($field)->@*) {
      my $val   = $alts->{val};
      my $form  = $alts->{form} // '';
      my $lang  = $alts->{lang} // '';


      $form = ($form eq 'default' or not $form) ? '' : "$omssep$form";
      $lang = ($lang eq Biber::Config->get_mslang($key) or not $lang) ? '' : "$omssep$lang";

      unless (Biber::Config->getoption('output_resolve_xdata')) {
        my $xd = xdatarefcheck($val);
        $val = $xd // $val;
      }

      # Could have been set in dates above (MONTH, YEAR special handling)
      $acc{$outmap->($field) . lc($form) . lc($lang)} = $val unless $acc{$outmap->($field) . lc($form) . lc($lang)};
    }
  }

  # XSV fields
  foreach my $field ($dmh->{xsv}->@*) {
    # keywords is by default field/xsv/keyword but it is in fact
    # output with its own special macro below
    next if $field eq 'keywords';
    foreach my $alts ($be->get_alternates_for_field($field)->@*) {
      my $f   = $alts->{val};
      my $form  = $alts->{form} // '';
      my $lang  = $alts->{lang} // '';

      $form = ($form eq 'default' or not $form) ? '' : "$omssep$form";
      $lang = ($lang eq Biber::Config->get_mslang($key) or not $lang) ? '' : "$omssep$lang";

      my $fl = join(',', $f->get_items->@*);
      unless (Biber::Config->getoption('output_resolve_xdata')) {
        my $xd = xdatarefcheck($fl);
        $fl = $xd // $fl;
      }
      $acc{$outmap->($field) . lc($form) . lc($lang)} .= $fl;
    }
  }

  # Ranges
  foreach my $rfield ($dmh->{ranges}->@*) {
    if ( my $rf = $be->get_field($rfield) ) {
      my $rfl = construct_range($rf);
      unless (Biber::Config->getoption('output_resolve_xdata')) {
        my $xd = xdatarefcheck($rfl);
        $rfl = $xd // $rfl;
      }
      $acc{$outmap->($rfield)} = $rfl;
    }
  }

  # Verbatim fields
  foreach my $vfield ($dmh->{vfields}->@*) {
    if ( my $vf = $be->get_field($vfield) ) {
      unless (Biber::Config->getoption('output_resolve_xdata')) {
        my $xd = xdatarefcheck($vf);
        $vf = $xd // $vf;
      }
      $acc{$outmap->($vfield)} = $vf;
    }
  }

  # Keywords
  if ( my $k = $be->get_field('keywords') ) {
    my $kl = join(',', $k->get_items->@*);
    unless (Biber::Config->getoption('output_resolve_xdata')) {
      my $xd = xdatarefcheck($kl);
      $kl = $xd // $kl;
    }
    $acc{$outmap->('keywords')} = $kl;
  }

  # Annotations
  foreach my $f (keys %acc) {
    my ($field, $form, $lang) = mssplit($f, $key);
    if (Biber::Annotation->is_annotated_field($key, lc($field), $form, $lang)) {
      foreach my $n (Biber::Annotation->get_annotation_names($key, lc($field), $form, $lang)) {
        my $nform = ($form eq 'default') ? '' : "$omssep$form";
        my $nlang = ($lang eq Biber::Config->get_mslang($key)) ? '' : "$omssep$lang";
        $acc{$outmap->($field) . lc($nform) . lc($nlang) . Biber::Config->getoption('output_annotation_marker') .
            Biber::Config->getoption('output_named_annotation_marker') . $n} = construct_annotation($key, lc($field), $n, $form, $lang);
      }
    }
  }

  # Determine maximum length of field names
  my $max_field_len;
  if (Biber::Config->getoption('output_align')) {
    $max_field_len = max map {Unicode::GCString->new($_)->length} keys %acc;
  }

  # Determine order of fields
  my %classmap = ('names'     => 'namelists',
                  'lists'     => 'lists',
                  'dates'     => 'datefields');


  foreach my $field (split(/\s*,\s*/, Biber::Config->getoption('output_field_order'))) {
    if ($field eq 'names' or
        $field eq 'lists' or
        $field eq 'dates') {
      my @donefields;
      foreach my $key (sort keys %acc) {
        if (first {fc($_) eq fc(msfield(strip_annotation($key)))} $dmh->{$classmap{$field}}->@*) {
          $acc .= bibfield($key, $acc{$key}, $max_field_len);
          push @donefields, $key;
        }
      }
      delete @acc{@donefields};
    }
    elsif (my $value = delete $acc{$outmap->($field)}) {
      $acc .= bibfield($outmap->($field), $value, $max_field_len);
    }
  }

  # Now rest of fields not explicitly specified
  foreach my $field (sort keys %acc) {
    $acc .= bibfield($field, $acc{$field}, $max_field_len);
  }

  $acc .= "}\n\n";

  # If requested to convert UTF-8 to macros ...
  if (Biber::Config->getoption('output_safechars')) {
    $acc = latex_recode_output($acc);
  }
  else { # ... or, check for encoding problems and force macros
    my $outenc = Biber::Config->getoption('output_encoding');
    if ($outenc ne 'UTF-8') {
      # Can this entry be represented in the output encoding?
      if (encode($outenc, NFC($acc)) =~ /\?/) { # Malformed data encoding char
        # So convert to macro
        $acc = latex_recode_output($acc);
        biber_warn("The entry '$key' has characters which cannot be encoded in '$outenc'. Recoding problematic characters into macros.");
      }
    }
  }

  # Create an index by keyname for easy retrieval
  $self->{output_data}{ENTRIES}{$secnum}{index}{$key} = \$acc;

  return;
}


=head2 output

    output method

=cut

sub output {
  my $self = shift;
  my $data = $self->{output_data};

  my $target_string = "Target"; # Default
  if ($self->{output_target_file}) {
    $target_string = $self->{output_target_file};
  }

  # Instantiate output file now that input is read in case we want to do in-place
  # output for tool mode
  my $enc_out;
  if (Biber::Config->getoption('output_encoding')) {
    $enc_out = ':encoding(' . Biber::Config->getoption('output_encoding') . ')';
  }
  my $target = IO::File->new($target_string, ">$enc_out");

  # for debugging mainly
  if (not $target or $target_string eq '-') {
    $target = new IO::File '>-';
  }

  if ($logger->is_debug()) {# performance tune
    $logger->debug('Preparing final output using class ' . __PACKAGE__ . '...');
  }

  $logger->info("Writing '$target_string' with encoding '" . Biber::Config->getoption('output_encoding') . "'");
  $logger->info('Converting UTF-8 to TeX macros on output') if Biber::Config->getoption('output_safechars');

  out($target, $data->{HEAD});

  # Output any macros when in tool mode
  if (Biber::Config->getoption('tool')) {
    if (exists($data->{MACROS})) {
      foreach my $macro (sort $data->{MACROS}->@*) {
        out($target, $macro);
      }
      out($target, "\n"); # Extra newline between macros and entries, for clarity
    }
  }

  if ($logger->is_debug()) {# performance tune
    $logger->debug("Writing entries in bibtex format");
  }

  # Bibtex output uses just one special section, always sorted by global sorting spec
  foreach my $key ($Biber::MASTER->datalists->get_lists_by_attrs(section => 99999,
                                                                 name => Biber::Config->getblxoption(undef, 'sortingtemplatename') . '/global//global/global',
                                                                 type => 'entry',
                                                                 sortingtemplatename => Biber::Config->getblxoption(undef, 'sortingtemplatename'),
                                                                 sortingnamekeytemplatename => 'global',
                                                                 labelprefix => '',
                                                                 uniquenametemplatename => 'global',
                                                                 labelalphanametemplatename => 'global')->[0]->get_keys->@*) {
    out($target, ${$data->{ENTRIES}{99999}{index}{$key}});
  }

  # Output any comments when in tool mode
  if (Biber::Config->getoption('tool')) {
    foreach my $comment ($data->{COMMENTS}->@*) {
      out($target, $comment);
    }
  }

  out($target, $data->{TAIL});

  $logger->info("Output to $target_string");
  close $target;
  return;
}

=head2 create_output_section

    Create the output from the sections data and push it into the
    output object.

=cut

sub create_output_section {
  my $self = shift;
  my $secnum = $Biber::MASTER->get_current_section;
  my $section = $Biber::MASTER->sections->get_section($secnum);

  # We rely on the order of this array for the order of the .bib
  foreach my $k ($section->get_citekeys) {
    # Regular entry
    my $be = $section->bibentry($k) or biber_error("Cannot find entry with key '$k' to output");
    $self->set_output_entry($be, $section, Biber::Config->get_dm);
  }

  # Create the comments output
  foreach my $comment ($Biber::MASTER->{comments}->@*) {
    $self->set_output_comment($comment);
  }

  # Create the macros output unless suppressed. This has to come after entry output creation
  # above as this gather information on which macros were actually used
  unless (Biber::Config->getoption('nooutputmacros')) {
    foreach my $m (sort values %RSTRINGS) {
      $self->set_output_macro($m);
    }
  }

  # Make sure the output object knows about the output section
  $self->set_output_section($secnum, $section);

  return;
}

=head2 bibfield

  Format a single field

=cut

sub bibfield {
  my ($field, $value, $max_field_len) = @_;
  my $acc;
  $acc .= ' ' x Biber::Config->getoption('output_indent');
  $acc .= $field;
  $acc .= ' ' x ($max_field_len - Unicode::GCString->new($field)->length) if $max_field_len;
  $acc .= ' = ';

  # Is the field value a macro? If so, replace with macro
  if (my $m = $RSTRINGS{$value}) {
    # Make the right casing function
    my $casing;

    if (Biber::Config->getoption('output_fieldcase') eq 'upper') {
      $casing = sub {uc(shift)};
    }
    elsif (Biber::Config->getoption('output_fieldcase') eq 'lower') {
      $casing = sub {lc(shift)};
    }
    elsif (Biber::Config->getoption('output_fieldcase') eq 'title') {
      $casing = sub {ucfirst(shift)};
    }

    $value = $casing->($m);
    $USEDSTRINGS{$m} = 1;
  }

  # Don't wrap fields which should be macros in braces - we can only deal with macros
  # which are the whole field value - too messy to check for part values and this is better
  # handles with XDATA anyway.
  # Don't check %RSTRINGS here as macros can come from other places (like %MONTHS). Just check
  # whether a macro is defined as that covers all sources
  if (Text::BibTeX::macro_length($value)) {
    $acc .= "$value,\n";
  }
  else {
    $acc .= "\{$value\},\n";
  }
  return $acc;
}


=head2 construct_annotation

  Construct a field annotation

=cut

sub construct_annotation {
  my ($key, $field, $name, $form, $lang) = @_;
  my @annotations;

  if (my $fa = Biber::Annotation->get_field_annotation($key, $field, $name, $form, $lang)) {
    push @annotations, "=$fa";
  }

  foreach my $item (Biber::Annotation->get_annotated_items('item', $key, $field, $name, $form, $lang)) {
    push @annotations, "$item=" . Biber::Annotation->get_annotation('item', $key, $field, $form, $lang, $name, $item);
  }

  foreach my $item (Biber::Annotation->get_annotated_items('part', $key, $field, $name, $form, $lang)) {
    foreach my $part (Biber::Annotation->get_annotated_parts('part', $key, $field, $name, $item, $form, $lang)) {
      push @annotations, "$item:$part=" . Biber::Annotation->get_annotation('part', $key, $field, $form, $lang, $name, $item, $part);
    }
  }

  return join(';', @annotations);
}

=head2 construct_range

  Construct a range field from its components

  [m, n]      -> m-n
  [m, undef]  -> m
  [m, '']     -> m-
  ['', n]     -> -n
  ['', undef] -> ignore

=cut

sub construct_range {
  my $r = shift;
  my @ranges;
  foreach my $e ($r->@*) {
    my $rs = $e->[0];
    if (defined($e->[1])) {
      $rs .= '--' . $e->[1];
    }
    push @ranges, $rs;
  }
  return join(',', @ranges);
}

=head2 construct_datetime

  Construct a datetime from its components

=cut

sub construct_datetime {
  my ($be, $d) = @_;
  my $datestring = '';
  my $overridey;
  my $overridem;
  my $overrideem;
  my $overrided;

  my %seasons = ( 'spring' => 21,
                  'summer' => 22,
                  'autumn' => 23,
                  'winter' => 24 );

  # Did the date fields come from interpreting an ISO8601-2:2016 unspecified date?
  # If so, do the reverse of Biber::Utils::parse_date_unspecified()
  if (my $unspec = $be->get_field("${d}dateunspecified")) {

    # 1990/1999 -> 199X
    if ($unspec eq 'yearindecade') {
      my ($decade) = $be->get_field("${d}year") =~ m/^(\d+)\d$/;
      $overridey = "${decade}X";
      $be->del_field("${d}endyear");
    }
    # 1900/1999 -> 19XX
    elsif ($unspec eq 'yearincentury') {
      my ($century) = $be->get_field("${d}year") =~ m/^(\d+)\d\d$/;
      $overridey = "${century}XX";
      $be->del_field("${d}endyear");
    }
    # 1999-01/1999-12 => 1999-XX
    elsif ($unspec eq 'monthinyear') {
      $overridem = 'XX';
      $be->del_field("${d}endyear");
      $be->del_field("${d}endmonth");
    }
    # 1999-01-01/1999-01-31 -> 1999-01-XX
    elsif ($unspec eq 'dayinmonth') {
      $overrided = 'XX';
      $be->del_field("${d}endyear");
      $be->del_field("${d}endmonth");
      $be->del_field("${d}endday");
    }
    # 1999-01-01/1999-12-31 -> 1999-XX-XX
    elsif ($unspec eq 'dayinyear') {
      $overridem = 'XX';
      $overrided = 'XX';
      $be->del_field("${d}endyear");
      $be->del_field("${d}endmonth");
      $be->del_field("${d}endday");
    }
  }

  # Seasons derived from EDTF dates
  if (my $s = $be->get_field("${d}season")) {
    $overridem = $seasons{$s};
  }
  if (my $s = $be->get_field("${d}endseason")) {
    $overrideem = $seasons{$s};
  }

  # date exists if there is a start year
  if (my $sy = $overridey || $be->get_field("${d}year") ) {
    $datestring .= $sy;
    $be->del_field("${d}year");

    # Start month
    if (my $sm = $overridem || $be->get_field("${d}month")) {
      $datestring .= '-' . sprintf('%.2d', $sm);
      $be->del_field("${d}month");
    }

    # Start day
    if (my $sd = $overrided || $be->get_field("${d}day")) {
      $datestring .= '-' . sprintf('%.2d', $sd);
      $be->del_field("${d}day");
    }

    # Uncertain and approximate start date
    if ($be->get_field("${d}dateuncertain") and
        $be->get_field("${d}dateapproximate")) {
      $datestring .= '%';
    }
    else {
      # Uncertain start date
      if ($be->get_field("${d}dateuncertain")) {
        $datestring .= '?';
      }

      # Approximate start date
      if ($be->get_field("${d}dateapproximate")) {
        $datestring .= '~';
      }
    }

    # If start hour, there must be minute and second
    if (my $sh = $be->get_field("${d}hour")) {
      $datestring .= 'T' . sprintf('%.2d', $sh) . ':' .
        sprintf('%.2d', $be->get_field("${d}minute")) . ':' .
          sprintf('%.2d', $be->get_field("${d}second"));
      $be->del_field("${d}hour");
      $be->del_field("${d}minute");
      $be->del_field("${d}second");
    }

    # start timezone
    if (my $stz = $be->get_field("${d}timezone")) {
      $stz =~ s/\\bibtzminsep\s+/:/;
      $datestring .= $stz;
      $be->del_field("${d}timezone");
    }

    # End year, can be empty
    if ($be->field_exists("${d}endyear")) {
      $datestring .= '/';
    }

    # End year
    if (my $ey = $be->get_field("${d}endyear")) {
      $datestring .= $ey;
      $be->del_field("${d}endyear");

      # End month
      if (my $em = $overrideem || $be->get_field("${d}endmonth")) {
        $datestring .= '-' . sprintf('%.2d', $em);
        $be->del_field("${d}endmonth");
      }

      # End day
      if (my $ed = $be->get_field("${d}endday")) {
        $datestring .= '-' . sprintf('%.2d', $ed);
        $be->del_field("${d}endday");
      }

      # Uncertain and approximate end date
      if ($be->get_field("${d}enddateuncertain") and
          $be->get_field("${d}enddateapproximate")) {
        $datestring .= '%';
      }
      else {
        # Uncertain end date
        if ($be->get_field("${d}enddateuncertain")) {
          $datestring .= '?';
        }

        # Approximate end date
        if ($be->get_field("${d}enddateapproximate")) {
          $datestring .= '~';
        }
      }

      # If end hour, there must be minute and second
      if (my $eh = $be->get_field("${d}endhour")) {
        $datestring .= 'T' . sprintf('%.2d', $eh) . ':' .
          sprintf('%.2d', $be->get_field("${d}endminute")) . ':' .
            sprintf('%.2d', $be->get_field("${d}endsecond"));
        $be->del_field("${d}endhour");
        $be->del_field("${d}endminute");
        $be->del_field("${d}endsecond");
      }

      # end timezone
      if (my $etz = $be->get_field("${d}endtimezone")) {
        $etz =~ s/\\bibtzminsep\s+/:/;
        $datestring .= $etz;
        $be->del_field("${d}endtimezone");
      }
    }
  }
  return $datestring;
}

1;

__END__

=head1 AUTHORS

Philip Kime C<< <philip at kime.org.uk> >>

=head1 BUGS

Please report any bugs or feature requests on our Github tracker at
L<https://github.com/plk/biber/issues>.

=head1 COPYRIGHT & LICENSE

Copyright 2009-2012 François Charette and Philip Kime, all rights reserved.
Copyright 2012-2020 Philip Kime, all rights reserved.

This module is free software.  You can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

This program is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=cut
