package Biber::Output::biblatexml;
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
use XML::Writer;
use Unicode::Normalize;
my $logger = Log::Log4perl::get_logger('main');

=encoding utf-8

=head1 NAME

Biber::Output::biblatexml - class for biblatexml output

=cut


=head2 new

    Initialize a Biber::Output::biblatexml object

=cut

sub new {
  my $class = shift;
  my $obj = shift;
  my $self;
  if (defined($obj) and ref($obj) eq 'HASH') {
    $self = bless $obj, $class;
  }
  else {
    $self = bless {}, $class;
  }

  return $self;
}


=head2 set_output_target_file

    Set the output target file of a Biber::Output::biblatexml object
    A convenience around set_output_target so we can keep track of the
    filename

=cut

sub set_output_target_file {
  my ($self, $toolfile, $init) = @_;

  # biblatexml output is only in tool mode and so we are looking at a data source name in
  # $ARGV[0]
  my $exts = join('|', values %DS_EXTENSIONS);
  my $schemafile = Biber::Config->getoption('dsn') =~ s/\.(?:$exts)$/.rng/r;

  $self->{output_target_file} = $toolfile;

  # Initialise any output object like an XML Writer
  if ($init) {
    my $bltxml = 'http://biblatex-biber.sourceforge.net/biblatexml';
    $self->{xml_prefix} = $bltxml;

    my $of;
    if ($toolfile eq '-') {
      open($of, '>&:encoding(UTF-8)', STDOUT);
    }
    else {
      $of = IO::File->new($toolfile, '>:encoding(UTF-8)');
    }
    $of->autoflush;             # Needed for running tests to string refs

    my $xml = XML::Writer->new(OUTPUT      => $of,
                               ENCODING    => 'UTF-8',
                               DATA_MODE   => 1,
                               DATA_INDENT => Biber::Config->getoption('output_indent'),
                               NAMESPACES  => 1,
                               PREFIX_MAP  => {$bltxml => 'bltx'});
    $xml->xmlDecl();
    $xml->pi('xml-model', "href=\"$schemafile\" type=\"application/xml\" schematypens=\"http://relaxng.org/ns/structure/1.0\"");
    $xml->comment("Auto-generated by Biber::Output::biblatexml");
    $xml->startTag([$self->{xml_prefix}, 'entries']);
    return $xml;
  }
  return;
}

=head2 set_output_entry

  Set the output for an entry

=cut

sub set_output_entry {
  my ($self, $be, $section, $dm) = @_;
  my $bee = $be->get_field('entrytype');
  my $dmh = Biber::Config->get_dm_helpers;
  my $secnum = $section->number;
  my $key = $be->get_field('citekey');
  my $xml = $self->{output_target};
  my $xml_prefix = $self->{xml_prefix};
  my $xnamesep = Biber::Config->getoption('xnamesep');

  $xml->startTag([$xml_prefix, 'entry'], id => NFC($key), entrytype => NFC($bee));

  # Filter aliases which point to this key and insert them
  if (my @ids = sort grep {$section->get_citekey_alias($_) eq $key} $section->get_citekey_aliases) {
    $xml->startTag([$xml_prefix, 'ids']);
    $xml->startTag([$xml_prefix, 'list']);
    foreach my $id (@ids) {
      $xml->dataElement([$xml_prefix, 'item'], NFC($id));
    }
    $xml->endTag();# list
    $xml->endTag();# ids
  }

  # If CROSSREF and XDATA have been resolved, don't output them
  # We can't use the usual skipout test for fields not to be output
  # as this only refers to .bbl output and not to biblatexml output since this
  # latter is not really a "processed" output, it is supposed to be something
  # which could be again used as input and so we don't want to resolve/skip
  # fields like DATE etc.
  # This only applies to the XDATA field as more granular XDATA will already
  # have/have not been resolved on the basis of this variable
  unless (Biber::Config->getoption('output_resolve_xdata')) {
    if (my $xdata = $be->get_field('xdata')) {
      $xml->startTag([$xml_prefix, 'xdata']);
      $xml->startTag([$xml_prefix, 'list']);
      foreach my $xd ($xdata->get_items->@*) {
        $xml->dataElement([$xml_prefix, 'item'], NFC($xd));
      }
      $xml->endTag(); # list
      $xml->endTag(); # xdata
    }
  }
  unless (Biber::Config->getoption('output_resolve_crossrefs')) {
    if (my $crossref = $be->get_field('crossref')) {
      $xml->dataElement([$xml_prefix, 'crossref'], NFC($crossref));
    }
  }

  # Per-entry options
  my @entryoptions;
  foreach my $opt (Biber::Config->getblxentryoptions($secnum, $key)) {
    push @entryoptions, $opt . '=' . Biber::Config->getblxoption($secnum, $opt, undef, $key);
  }
  $xml->dataElement([$xml_prefix, 'options'], NFC(join(',', @entryoptions))) if @entryoptions;

  # Output name fields
  foreach my $namefield ($dm->get_fields_of_type('list', 'name')->@*) {

    # Name loop
    foreach my $alts ($be->get_alternates_for_field($namefield)->@*) {
      my $nf = $alts->{val};
      my $form  = $alts->{form} // '';
      my $lang  = $alts->{lang} // '';

      $form = ($form eq 'default' or not $form) ? '' : $form;
      $lang = ($lang eq Biber::Config->get_mslang($key) or not $lang) ? '' : $lang;

      # XDATA is special
      if (not Biber::Config->getoption('output_resolve_xdata') or
         not $be->is_xdata_resolved($namefield, $form, $lang)) {
        if (my $xdata = $nf->get_xdata) {
          $xml->emptyTag([$xml_prefix, 'names'], 'xdata' => NFC(xdatarefout($xdata, 1)));
          next;
        }
      }

      my @attrs = ('type' => $namefield);

      # form/lang
      push @attrs, (msform => $form) if $form;
      push @attrs, (mslang => $lang) if $lang;

      # Did we have "and others" in the data?
      if ( $nf->get_morenames ) {
        push @attrs, (morenames => 1);
      }

      # Add per-namelist options
      foreach my $nlo (keys $CONFIG_SCOPEOPT_BIBLATEX{NAMELIST}->%*) {
        if (defined($nf->${\"get_$nlo"})) {
          my $nlov = $nf->${\"get_$nlo"};

          if ($CONFIG_BIBLATEX_OPTIONS{NAMELIST}{$nlo}{OUTPUT}) {
            push @attrs, ($nlo => map_boolean($nlo, $nlov, 'tostring'));
          }
        }
      }

      $xml->startTag([$xml_prefix, 'names'], @attrs);

      for (my $i = 0; $i <= $nf->names->$#*; $i++) {
        my $n = $nf->names->[$i];

        # XDATA is special
        if (not Biber::Config->getoption('output_resolve_xdata') or
           not $be->is_xdata_resolved($namefield, $form, $lang, $i+1)) {
          if (my $xdata = $n->get_xdata) {
            $xml->emptyTag([$xml_prefix, 'name'], 'xdata' => NFC(xdatarefout($xdata, 1)));
            next;
          }
        }

        $n->name_to_biblatexml($self, $xml, $key, $namefield, $n->get_index);
      }

      $xml->endTag(); # Names
    }
  }

  # Output list fields
  foreach my $listfield (sort $dm->get_fields_of_fieldtype('list')->@*) {
    next if $dm->field_is_datatype('name', $listfield); # name is a special list

    # List loop
    foreach my $alts ($be->get_alternates_for_field($listfield)->@*) {
      my $lf = $alts->{val};
      my $form  = $alts->{form} // '';
      my $lang  = $alts->{lang} // '';

      $form = ($form eq 'default' or not $form) ? '' : $form;
      $lang = ($lang eq Biber::Config->get_mslang($key) or not $lang) ? '' : $lang;

      # XDATA is special
      if (not Biber::Config->getoption('output_resolve_xdata') or
          not $be->is_xdata_resolved($listfield, $form, $lang)) {
        if (my $val = xdatarefcheck($lf, 1)) {
          $xml->emptyTag([$xml_prefix, $listfield], 'xdata' => NFC($val));
          next;
        }
      }

      my @attrs;

      # form/lang
      push @attrs, (msform => $form) if $form;
      push @attrs, (mslang => $lang) if $lang;

      # Did we have a "more" list?
      if (lc($lf->last_item) eq Biber::Config->getoption('others_string') ) {
        push @attrs, (morelist => 1);
        $lf->del_last_item;
      }

      $xml->startTag([$xml_prefix, $listfield], @attrs);
      $xml->startTag([$xml_prefix, 'list']);

      # List loop
      for (my $i = 0; $i <= $lf->count-1; $i++) {
        my $f = $lf->get_items->[$i];
        my @lattrs;

        # XDATA is special
        if (not Biber::Config->getoption('output_resolve_xdata') or
            not $be->is_xdata_resolved($listfield, $form, $lang, $i+1)) {
          if (my $val = xdatarefcheck($f, 1)) {
            $xml->emptyTag([$xml_prefix, 'item'], 'xdata' => NFC($val));
            next;
          }
        }

        $xml->dataElement([$xml_prefix, 'item'], NFC($f));
      }
      $xml->endTag();           # list
      $xml->endTag();           # listfield
    }
  }

  # Standard fields
  foreach my $field (sort $dm->get_fields_of_type('field',
                                                  ['entrykey',
                                                   'key',
                                                   'literal',
                                                   'code',
                                                   'integer',
                                                   'verbatim',
                                                   'uri'])->@*) {
    foreach my $alts ($be->get_alternates_for_field($field)->@*) {
      my $val = $alts->{val};
      my $form  = $alts->{form} // '';
      my $lang  = $alts->{lang} // '';

      $form = ($form eq 'default' or not $form) ? '' : $form;
      $lang = ($lang eq Biber::Config->get_mslang($key) or not $lang) ? '' : $lang;

      # XDATA is special
      if (not Biber::Config->getoption('output_resolve_xdata') or
          not $be->is_xdata_resolved($field, $form, $lang)) {

        if (my $xval = xdatarefcheck($val, 1)) {
          $xml->emptyTag([$xml_prefix, $field], 'xdata' => NFC($xval));
          next;
        }
      }

      if (length($val) or      # length() catches '0' values, which we want
          ($dm->field_is_nullok($field) and
           $be->field_exists($field, $form, $lang))) {
        next if $dm->get_fieldformat($field) eq 'xsv';
        next if $field eq 'crossref'; # this is handled above
        my @attrs;

        # form/lang
        push @attrs, (msform => $form) if $form;
        push @attrs, (mslang => $lang) if $lang;

        $xml->dataElement([$xml_prefix, $field], NFC($val), @attrs);
      }
    }
  }

  # xsv fields
  foreach my $xsvf ($dm->get_fields_of_type('field', 'xsv')->@*) {
    foreach my $alts ($be->get_alternates_for_field($xsvf)->@*) {
      my $f = $alts->{val};
      my $form  = $alts->{form} // '';
      my $lang  = $alts->{lang} // '';

      $form = ($form eq 'default' or not $form) ? '' : $form;
      $lang = ($lang eq Biber::Config->get_mslang($key) or not $lang) ? '' : $lang;

      next if $xsvf eq 'ids'; # IDS is special
      next if $xsvf eq 'xdata'; # XDATA is special

      # XDATA is special
      if (not Biber::Config->getoption('output_resolve_xdata') or
          not $be->is_xdata_resolved($xsvf, $form, $lang)) {
        if (my $val = xdatarefcheck($f, 1)) {
          $xml->emptyTag([$xml_prefix, $xsvf], 'xdata' => NFC($val));
          next;
        }
      }

      my @attrs;

      # form/lang
      push @attrs, (msform => $form) if $form;
      push @attrs, (mslang => $lang) if $lang;

      $xml->dataElement([$xml_prefix, $xsvf], NFC(join(',',$f->get_items->@*)), @attrs);
    }
  }

  # Range fields
  foreach my $rfield (sort $dm->get_fields_of_datatype('range')->@*) {
    if ( my $rf = $be->get_field($rfield) ) {

      # XDATA is special
      if (not Biber::Config->getoption('output_resolve_xdata') or
          not $be->is_xdata_resolved($rfield)) {
        if (my $val = xdatarefcheck($rf, 1)) {
          $xml->emptyTag([$xml_prefix, $rfield], 'xdata' => NFC($val));
          next;
        }
      }

      # range fields are an array ref of two-element array refs [range_start, range_end]
      # range_end can be be empty for open-ended range or undef
      $xml->startTag([$xml_prefix, $rfield]);
      $xml->startTag([$xml_prefix, 'list']);

      foreach my $f ($rf->@*) {
        $xml->startTag([$xml_prefix, 'item']);
        if (defined($f->[1])) {
          $xml->dataElement([$xml_prefix, 'start'], NFC($f->[0]));
          $xml->dataElement([$xml_prefix, 'end'], NFC($f->[1]));
        }
        else {
          $xml->characters(NFC($f->[0]));
        }
        $xml->endTag();# item
      }
      $xml->endTag();# list
      $xml->endTag();# range
    }
  }

  # Date fields
  my %dinfo;
  foreach my $datefield (sort $dm->get_fields_of_datatype('date')->@*) {
    my @attrs;
    my @start;
    my @end;
    my $overridey;
    my $overridem;
    my $overrideem;
    my $overrided;

    my ($d) = $datefield =~ m/^(.*)date$/;
    if (my $sf = $be->get_field("${d}year") ) { # date exists if there is a year

      push @attrs, ('type', $d) if $d; # ignore for main date

      $xml->startTag([$xml_prefix, 'date'], @attrs);

      # Uncertain and approximate dates
      if ($be->get_field("${d}dateuncertain") and
          $be->get_field("${d}dateapproximate")) {
        $sf .= '%';
      }
      else {
        # Uncertain dates
        if ($be->get_field("${d}dateuncertain")) {
          $sf .= '?';
        }

        # Approximate dates
        if ($be->get_field("${d}dateapproximate")) {
          $sf .= '~';
        }
      }

      # Unknown dates
      if ($be->get_field("${d}dateunknown")) {
        $sf = 'unknown';
      }

      my %yeardivisions = ( 'spring'  => 21,
                            'summer'  => 22,
                            'autumn'  => 23,
                            'winter'  => 24,
                            'springN' => 25,
                            'summerN' => 26,
                            'autumnN' => 27,
                            'winterN' => 28,
                            'springS' => 29,
                            'summerS' => 30,
                            'autumnS' => 31,
                            'WinterS' => 32,
                            'Q1'      => 33,
                            'Q2'      => 34,
                            'Q3'      => 35,
                            'Q4'      => 36,
                            'QD1'     => 37,
                            'QD2'     => 38,
                            'QD3'     => 39,
                            'S1'      => 40,
                            'S2'      => 41 );

      # Did the date fields come from interpreting an iso8601-2 unspecified date?
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

      # Seasons derived from iso8601 dates
      if (my $s = $be->get_field("${d}yeardivision")) {
        $overridem = $yeardivisions{$s};
      }
      if (my $s = $be->get_field("${d}endyeardivision")) {
        $overrideem = $yeardivisions{$s};
      }
      $sf = $overridey || $sf;

      # strip undefs
      push @start,
        grep {$_}
          $sf,
            date_monthday($overridem || $be->get_field("${d}month")),
              date_monthday($overrided || $be->get_field("${d}day"));
      push @end,
        grep {defined($_)} # because end can be def but empty
          $be->get_field("${d}endyear"),
            date_monthday($overrideem || $be->get_field("${d}endmonth")),
              date_monthday($be->get_field("${d}endday"));
      # Date range
      if (@end) {
        my $start = NFC(join('-', @start));
        my $end = NFC(join('-', @end));

        # If start hour, there must be minute and second
        if (my $sh = $be->get_field("${d}hour")) {
          $start .= NFC('T' . sprintf('%.2d', $sh) . ':' .
            sprintf('%.2d', $be->get_field("${d}minute")) . ':' .
              sprintf('%.2d', $be->get_field("${d}second")));
        }

        # start timezone
        if (my $stz = $be->get_field("${d}timezone")) {
          $stz =~ s/\\bibtzminsep\s+/:/;
          $start .= NFC($stz);
        }

        # If end hour, there must be minute and second
        if (my $eh = $be->get_field("${d}endhour")) {
          $end .= NFC('T' . sprintf('%.2d', $eh) . ':' .
            sprintf('%.2d', $be->get_field("${d}endminute")) . ':' .
              sprintf('%.2d', $be->get_field("${d}endsecond")));
        }

        # end timezone
        if (my $etz = $be->get_field("${d}endtimezone")) {
          $etz =~ s/\\bibtzminsep\s+/:/;
          $end .= NFC($etz);
        }

        $xml->dataElement([$xml_prefix, 'start'], $start);
        $xml->dataElement([$xml_prefix, 'end'], $end);
      }
      else { # simple date
        $xml->characters(NFC(join('-', @start)));

        # If start hour, there must be minute and second
        if (my $sh = $be->get_field("${d}hour")) {
          $xml->characters(NFC('T' . sprintf('%.2d', $sh) . ':' .
                               sprintf('%.2d', $be->get_field("${d}minute")) . ':' .
                               sprintf('%.2d', $be->get_field("${d}second"))));
        }

        # start timezone
        if (my $stz = $be->get_field("${d}timezone")) {
          $stz =~ s/\\bibtzminsep\s+/:/;
          $xml->characters(NFC($stz));
        }
      }
      $xml->endTag();           # date
    }
  }

  # Annotations
  foreach my $f (Biber::Annotation->get_annotated_fields('field', $key)) {
    foreach my $form (Biber::Annotation->get_annotation_forms($key, $f)) {
      foreach my $lang (Biber::Annotation->get_annotation_langs($key, $f, $form)) {
        foreach my $n (Biber::Annotation->get_annotations('field', $key, $f, $form, $lang)) {
          my $v = Biber::Annotation->get_annotation('field', $key, $f, $form, $lang, $n);
          my $l = Biber::Annotation->is_literal_annotation('field', $key, $f, $form, $lang, $n);

          my @ms;
          if ($dm->is_multiscript($f)) {
            push @ms, ('msform' => $form) unless $form eq 'default';
            push @ms, ('mslang' => $lang) unless $lang eq Biber::Config->get_mslang($key);
          }
          $xml->dataElement([$xml_prefix, 'annotation'],
                            $v,
                            field => $f,
                            @ms,
                            name  => $n,
                            literal => $l);
        }
      }
    }
  }

  foreach my $f (Biber::Annotation->get_annotated_fields('item', $key)) {
    foreach my $form (Biber::Annotation->get_annotation_forms($key, $f)) {
      foreach my $lang (Biber::Annotation->get_annotation_langs($key, $f, $form)) {
        foreach my $n (Biber::Annotation->get_annotations('item', $key, $f, $form, $lang)) {
          foreach my $c (Biber::Annotation->get_annotated_items('item', $key, $f, $n, $form, $lang)) {
            my $v = Biber::Annotation->get_annotation('item', $key, $f, $form, $lang, $n, $c);
            my $l = Biber::Annotation->is_literal_annotation('item', $key, $f, $form, $lang, $n, $c);
            my @ms;
            if ($dm->is_multiscript($f)) {
              push @ms, ('msform' => $form) unless $form eq 'default';
              push @ms, ('mslang' => $lang) unless $lang eq Biber::Config->get_mslang($key);
            }

            $xml->dataElement([$xml_prefix, 'annotation'],
                              $v,
                              field => $f,
                              @ms,
                              name  => $n,
                              item => $c,
                              literal => $l);
          }
        }
      }
    }
  }

  foreach my $f (Biber::Annotation->get_annotated_fields('part', $key)) {
    foreach my $form (Biber::Annotation->get_annotation_forms($key, $f)) {
      foreach my $lang (Biber::Annotation->get_annotation_langs($key, $f, $form)) {
        foreach my $n (Biber::Annotation->get_annotations('part', $key, $f, $form, $lang)) {
          foreach my $c (Biber::Annotation->get_annotated_items('part', $key, $f, $n, $form, $lang)) {
            foreach my $p (Biber::Annotation->get_annotated_parts('part', $key, $f, $n, $c, $form, $lang)) {
              my $v = Biber::Annotation->get_annotation('part', $key, $f, $form, $lang, $n, $c, $p);
              my $l = Biber::Annotation->is_literal_annotation('part', $key, $f, $form, $lang, $n, $c, $p);
              my @ms;
              if ($dm->is_multiscript($f)) {
                push @ms, ('msform' => $form) unless $form eq 'default';
                push @ms, ('mslang' => $lang) unless $lang eq Biber::Config->get_mslang($key);
              }
              $xml->dataElement([$xml_prefix, 'annotation'],
                                $v,
                                field => $f,
                                @ms,
                                name  => $n,
                                item => $c,
                                part => $p,
                                literal => $l);
            }
          }
        }
      }
    }
  }

  $xml->endTag();

  return;
}

=head2 output

    Tool output method

=cut

sub output {
  my $self = shift;
  my $data = $self->{output_data};
  my $xml = $self->{output_target};
  my $target_string = "Target"; # Default
  my $dm = Biber::Config->get_dm;
  if ($self->{output_target_file}) {
    $target_string = $self->{output_target_file};
  }

  if ($logger->is_debug()) {# performance tune
    $logger->debug('Preparing final output using class ' . __PACKAGE__ . '...');
    $logger->debug("Writing entries in tool mode");
  }
  $xml->endTag();
  $xml->end();

  $logger->info("Output to $target_string");
  my $exts = join('|', values %DS_EXTENSIONS);
  my $schemafile = Biber::Config->getoption('dsn') =~ s/\.(?:$exts)$/.rng/r;

  # Generate schema to accompany output
  unless (Biber::Config->getoption('no_bltxml_schema')) {
    $dm->generate_bltxml_schema($schemafile);
  }

  if (Biber::Config->getoption('validate_bltxml')) {
    validate_biber_xml($target_string, 'bltx', 'http://biblatex-biber.sourceforge.net/biblatexml', $schemafile);
  }

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

  # We rely on the order of this array for the order of the output
  foreach my $k ($section->get_citekeys) {
    # Regular entry
    my $be = $section->bibentry($k) or biber_error("Cannot find entry with key '$k' to output");
    $self->set_output_entry($be, $section, Biber::Config->get_dm);
  }

  # Make sure the output object knows about the output section
  $self->set_output_section($secnum, $section);

  return;
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
Copyright 2012-2022 Philip Kime, all rights reserved.

This module is free software.  You can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

This program is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=cut
