package XrefMapper::tetraodon_nigroviridis;

use  XrefMapper::BasicMapper;

use vars '@ISA';

@ISA = qw{ XrefMapper::BasicMapper };

# Same as in BasicMapper but Genoscope order reversed.

sub transcript_display_xref_sources {

  return ('HUGO',
	  'MarkerSymbol',
	  'wormbase_transcript',
	  'flybase_symbol',
	  'Anopheles_symbol',
	  'Genoscope_annotated_gene',
	  'Genoscope_predicted_transcript',
	  'Uniprot/SWISSPROT',
	  'RefSeq',
	  'Uniprot/SPTREMBL',
	  'LocusLink');

}

1;
