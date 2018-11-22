=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2019] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package XrefParser::RefSeqGPFFParser;

use strict;
use warnings;
use Carp;
use List::MoreUtils qw(uniq);
use Readonly;

use parent qw( XrefParser::BaseParser );

# Refseq sources to consider. Prefixes not in this list will be ignored
Readonly my $REFSEQ_SOURCES => {
    NM => 'RefSeq_mRNA',
    NR => 'RefSeq_ncRNA',
    XM => 'RefSeq_mRNA_predicted',
    XR => 'RefSeq_ncRNA_predicted',
    NP => 'RefSeq_peptide',
    XP => 'RefSeq_peptide_predicted',
};


sub run {
  my ($self, $ref_arg) = @_;

  my $source_id    = $ref_arg->{source_id};
  my $species_id   = $ref_arg->{species_id};
  my $species_name = $ref_arg->{species};
  my $files        = $ref_arg->{files};
  my $release_file = $ref_arg->{rel_file};
  my $dbi          = $ref_arg->{dbi} // $self->dbi;
  my $verbose      = $ref_arg->{verbose} // 0;

  if((!defined $source_id) or (!defined $species_id) or (!defined $files)){
    croak "Need to pass source_id, species_id, files and rel_file as pairs";
  }

  $self->{species_id} = $species_id;
  $self->{dbi} = $dbi;
  $self->{verbose} = $verbose;

  # get RefSeq source ids
  while (my ($source_prefix, $source_name) = each %{$REFSEQ_SOURCES}) {
    $self->{source_ids}->{$source_name} = $self->get_source_id_for_source_name( $source_name, undef, $dbi )
  }

  # get extra source ids
  $self->{source_ids}->{EntrezGene} = $self->get_source_id_for_source_name('EntrezGene', undef, $dbi);
  $self->{source_ids}->{WikiGene} = $self->get_source_id_for_source_name('WikiGene', undef, $dbi);

  # Retrieve existing RefSeq mRNA
  $self->{refseq_ids} = { %{$self->get_valid_codes('RefSeq_mRNA', $species_id, $dbi)},
      %{$self->get_valid_codes('RefSeq_mRNA_predicted', $species_id, $dbi)} };
  $self->{entrez_ids} = $self->get_valid_codes('EntrezGene', $species_id, $dbi);
  $self->{wiki_ids} = $self->get_valid_codes('WikiGene', $species_id, $dbi);

  if ($verbose) {
    for my $source_name (sort values %{$REFSEQ_SOURCES}) {
      print "$source_name source ID = $self->{source_ids}->{$source_name}\n";
    }
  }

  # populate entrez gene id => label hash
  $self->{entrez} = $self->get_acc_to_label('EntrezGene', $species_id, undef, $dbi);

  # get the species name, prepare species related data checks
  my %species2name = $self->species_id2name($dbi);
  $species_name //= shift @{$species2name{$species_id}};

  $self->{name2species_id} = { map{ $_=>$species_id } @{$species2name{$species_id}} };
  my %species2tax  = $self->species_id2taxonomy($dbi);
  $self->{taxonomy2species_id} = { map{ $_=>$species_id } @{$species2tax{$species_id}} };

  # process the source files
  GENBANK:
  foreach my $file (@{$files}) {

    # type from the file (peptide or dna)
    my $type = $self->type_from_file($file);

    # get the file handler
    my $refseq_fh = $self->get_filehandle($file);

    if ( !defined $refseq_fh ) {
      warn "WARNING: Can't open RefSeqGPFF file $file\n";
      return;
    }

    # this will hold the array of xrefs to bulk insert
    my $xrefs;

    do {
      local $/ = "\/\/\n";
      while ( my $item = $refseq_fh->getline() ) {
        my $xref = $self->xref_from_record({
          record => $item,
          type   => $type
        });

        if (defined $xref) {
          push @{$xrefs}, $xref;
        }
      }
    };

    $refseq_fh->close();

    # no xrefs in this file...
    if ( !defined( $xrefs ) ) {
      next GENBANK;
    }

    # upload the xrefs
    $self->upload_xref_object_graphs( $xrefs, $dbi );

  }


  # process the release file
  if ( defined $release_file ) {
    # get filehandle
    my $release_fh = $self->get_filehandle($release_file);

    # get file header
    my $release = do { local $/ = "\n*"; <$release_fh> };
    $release_fh->close();

    $release =~ s/\s+/ /xg;

    if ( $release =~ m/(NCBI.*Release\s\d+)\s(.*)\sDistribution/x ) {
      my ($rel_number, $rel_date) = ($1, $2);
      my $release_string = "$rel_number, $rel_date";

      # set release info
      $self->set_release( $source_id, $release_string, $dbi );
      for my $source_name (sort values %{$REFSEQ_SOURCES}) {
        $self->set_release( $self->{source_ids}->{$source_name}, $release_string, $dbi );
      }
      if ($verbose) {
        print "RefSeq release: '$release_string'\n";
      }
    } else {
      warn "WARNING: Could not set release info from release file '$release_file'\n";
    }

  } else {
    warn "WARNING: No release_file available\n";
  }

  return 0;
}



# provided a params hash containing record and type, returns xref for bulk insert and creates related dependent_xrefs
sub xref_from_record {
  my ($self, $params) = @_;


  my $genbank_rec = $params->{record};

  # Get the record species
  my ($record_species) = $genbank_rec =~ /ORGANISM\s*(.*)\n/x;
  $record_species = lc $record_species;
  $record_species =~ s/\s+/_/xg;

  # get the record species id from the record name
  my $record_species_id = $self->{name2species_id}->{$record_species};

  # if not found try from the record taxon_id
  if ( !defined $record_species_id ) {
    my ($record_taxon) = $genbank_rec =~ /db_xref="taxon:(\d+)/x;
    $record_species_id = $self->{taxonomy2species_id}->{$record_taxon};
  }

  # skip if species is not the required
  return unless ( defined $record_species_id && ($record_species_id eq $self->{species_id}) );


  my ($acc) = $genbank_rec =~ /ACCESSION\s+(\S+)/x;

  my $acc_source_id = $self->source_id_from_acc($acc);

  my $xref = {
    ACCESSION     => $acc,
    SPECIES_ID    => $self->{species_id},
    SOURCE_ID     => $acc_source_id,
    SEQUENCE_TYPE => $params->{type},
    INFO_TYPE     => 'SEQUENCE_MATCH'
  };

  my ($ver_acc, $ver_num) = $genbank_rec =~ /VERSION\s+(\w+)\.(\d+)/x;

  if ($acc eq $ver_acc) {
    $xref->{LABEL} = "${acc}.${ver_num}";
    $xref->{VERSION} = $ver_num;
  } else {
    warn "WARNING: accession $acc mismatch with version ${acc}.${ver_num}\n" if $self->{verbose};
  }

  my ($description) = $genbank_rec =~ /DEFINITION\s+  # Find the field identifier
                                  (.*)                # get the description
                                  \s+ACCESSION/xms;   # until the next field

  # remove any newlines and spaces, and make sure is within mysql limits
  $description =~ s/\n//xg;
  $description =~ s/\s+/ /xg;
  $description = substr($description, 0, 255) if (length($description) > 255);

  $xref->{DESCRIPTION} = $description;

  # sequence is multiline, each line starts with base number and has spaces all over. ends with //
  my ($seq) = $genbank_rec =~ /\s*ORIGIN\s+ # Find the field identifier
                          (.+)         # get all sequence lines
                          \/\//xms;    # until the end of the field (//)

  # get rid of the base number and the whitespace for a sequence string
  $seq =~ s/[\d\s]+//xg;

  $xref->{SEQUENCE} = $seq;


  my @protein_ids = $genbank_rec =~ /\/protein_id=\"(.+?)\"/xg;

  my $protein_id = pop @protein_ids;

  $xref->{PROTEIN} = $protein_id if defined $protein_id;


  my @coded_by_list = $genbank_rec =~ /\/coded_by=\"(.*?):/xg;

  my $coded_by = pop @coded_by_list;

  $xref->{PAIR} = $coded_by if defined $coded_by;

  my ($refseq_pair) = $genbank_rec =~ /DBSOURCE\s+REFSEQ: accession (\S+)/x;
  if (!exists $xref->{PAIR}) {
    $xref->{PAIR} = $refseq_pair if defined $refseq_pair;
  }


  my @gene_ids = $genbank_rec =~ /db_xref=\"GeneID:(.+?)\"/xg;
  @gene_ids = uniq( @gene_ids );

  # process existing entrez_gene_ids as dependent xrefs
  GENEID:
  foreach my $gene_id (@gene_ids) {

    next GENEID unless (defined $self->{entrez}->{$gene_id});

    push @{$xref->{DEPENDENT_XREFS}}, {
        SOURCE_ID         => $self->source_id_from_name('EntrezGene'),
        LINKAGE_SOURCE_ID => $acc_source_id,
        ACCESSION         => $gene_id,
        LABEL             => $self->{entrez}->{$gene_id}
    };

    push @{$xref->{DEPENDENT_XREFS}}, {
        SOURCE_ID         => $self->source_id_from_name('WikiGene'),
        LINKAGE_SOURCE_ID => $acc_source_id,
        ACCESSION         => $gene_id,
        LABEL             => $self->{entrez}->{$gene_id}
    };

    next GENEID unless (defined $refseq_pair);

    # split the version number
    my ($pair_acc, $pair_version) = split(/\./x, $refseq_pair);

    # Add xrefs for RefSeq mRNA as well where available
    foreach my $refseq_acc (@{ $self->{refseq_accs}->{$pair_acc} }) {
      foreach my $entrez_id (@{ $self->{entrez_ids}->{$gene_id} }) {
        $self->add_dependent_xref({
          master_xref_id => $refseq_acc,
          acc            => $entrez_id,
          version        => $pair_version,
          source_id      => $self->source_id_from_name('EntrezGene'),
          species_id     => $self->{species_id},
          dbi            => $self->{dbi}
        });
      }
      foreach my $wiki_id (@{ $self->{wiki_ids}->{$gene_id} }) {
        $self->add_dependent_xref({
          master_xref_id => $refseq_acc,
          acc            => $wiki_id,
          version        => $pair_version,
          source_id      => $self->source_id_from_name('WikiGene'),
          species_id     => $self->{species_id},
          dbi            => $self->{dbi}
        });
      }
    }
  }

  return $xref;

}


# returns the source id for a source name, requires $self->{source_ids} to have been populated
sub source_id_from_name {
  my ($self, $name) = @_;

  my $source_id;

  if ( exists $self->{source_ids}->{$name} ) {
    $source_id = $self->{source_ids}->{$name};
  } elsif ( $self->{verbose} ) {
    warn "WARNING: can't get source ID for name '$name'\n";
  }

  return $source_id;
}

# returns the source id for a RefSeq accession, requires $self->{source_ids} to have been populated
sub source_id_from_acc {
  my ($self, $acc) = @_;

  my $source_id;
  my $prefix = substr($acc, 0, 2);

  if ( exists $REFSEQ_SOURCES->{$prefix} ) {
    $source_id = $self->source_id_from_name( $REFSEQ_SOURCES->{$prefix} );
  } elsif ( $self->{verbose} ) {
    warn "WARNING: can't get source ID for accession '$acc'\n";
  }

  return $source_id;
}

# get type from filename path. this includes the source name and that's enough to extract it
sub type_from_file {
  my ($self, $file) = @_;

  my ($type) = $file =~ /RefSeq_(\w+)\//x;

  warn "WARNING: Could not work out sequence type for '$file'\n" unless $type;

  return $type;
}

1;
