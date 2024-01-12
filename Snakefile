"""This file specifies the entire pipeline that will be run, with
specific parameters for subsampling, tree building, and visualization. In this
build, you will generate 1 tree: an H3Nx tree, using HA sequences sampled from
different host species from 1960-present. These viruses include H3 subtype HAs
packaged with any NA gene, hence, the H3Nx."""


"""This rule tells Snakemake that at the end of the pipeline, you should have
generated JSON files in the auspice folder for each subtype and segment."""
rule all:
    input:
        auspice_json = expand("auspice/h3nx_ha.json")

"""Specify all input files here. For this build, you'll start with input sequences
from the data folder, which contain metadata information in the
sequence header. Specify here files denoting specific strains to include or drop,
references sequences, and files for auspice visualization (colors)"""
rule files:
    params:
        input_sequences = "data/h3nx_ha.fa",
        dropped_strains = "config/exclude_strains.txt",
        reference = "config/reference_sequence_ha_A_mallard_Alberta_114_1997.gb",
        auspice_config = "config/auspice_config.json",
	    colors = "config/colors.tsv"


files = rules.files.params


"""In this section of the Snakefile, rules are specified for each step of the pipeline.
Each rule has inputs, outputs, parameters, and the specific text for the commands in
bash. Rules reference each other, so altering one rule may require changing another
if they depend on each other for inputs and outputs. Notes are included for
specific rules."""


"""The parse rule is used to separate out sequences and metadata into 2 distinct
files. This rule assumes an input fasta file that contains metadata information
in the header. By specifying the order of those fields in the `fasta_fields` line,
`augur parse` will separate those fields into labeled columns in the output metadata
file."""
rule parse:
    message: "Parsing fasta into sequences and metadata"
    input:
        sequences = files.input_sequences
    output:
        sequences = "results/sequences.fasta",
        metadata = "results/metadata.tsv"
    params:
        fasta_fields =  "strain accession subtype date host country region species broad order",
        prettify_fields = "country host species region order"   # this just does some text cleaning to make these labels nicer to read
    shell:
        """
        augur parse \
            --sequences {input.sequences} \
            --output-sequences {output.sequences} \
            --output-metadata {output.metadata} \
            --fields {params.fasta_fields} \
            --prettify-fields {params.prettify_fields}
        """

"""This rule specifies how to subsample data for the build, which is highly
customizable based on your desired tree. A few notes on specifics on the
subsampling arguments here:

1. include: all strain names specified in this include file will be force included
in the build.
2. exclude: all strain names specified in this exclude file will be subsampled
out of the build.
3. min_date: sequences with collection dates before this time will be removed
4. min_length: sequences with lengths less than this value will be removed
5. group_by and sequences_per_group: these 2 arguments are used in conjunction with
one another to set how many sequences should be sampled. Whichever columns you
specify in group_by will be used to generate subsets of the data by those groups.
For example, if you specify "year host", Nextstrain will generate 1 group per
combation of year and host (e.g., "2000 dog", "2000 horse", "2001 dog", "2001 horse",
etc...). Then, from each of those groups, it will sample, at random, the number
of sequences specified in the "group_by" specification.

"""

rule filter:
    message:
        """
        Filtering to
          - {params.sequences_per_group} sequence(s) per {params.group_by!s}
          - excluding strains in {input.exclude}
          - samples with missing region and country metadata
          - excluding strains prior to {params.min_date}
        """
    input:
        sequences = rules.parse.output.sequences,
        metadata = rules.parse.output.metadata,
        exclude = files.dropped_strains
    output:
        sequences = "results/filtered.fasta"
    params:
        group_by = "year host subtype region",
        sequences_per_group = "300",  # subsample the data to 10 sequences per year, host, subtype, and region
        min_date = "1900",
        min_length = "1600",  # we want to retain mostly complete sequences
        exclude_where = "host=ferret"   # ferret sequences are usually from experimental infection studies, which we want to exclude

    shell:
        """
        augur filter \
            --sequences {input.sequences} \
            --metadata {input.metadata} \
            --exclude {input.exclude} \
            --output {output.sequences} \
            --group-by {params.group_by} \
            --sequences-per-group {params.sequences_per_group} \
            --min-date {params.min_date} \
            --exclude-where {params.exclude_where} \
            --min-length {params.min_length} \
            --non-nucleotide
        """

rule align:
    message:
        """
        Aligning sequences to {input.reference}
          - filling gaps with N
        """
    input:
        sequences = rules.filter.output.sequences,
        reference = files.reference
    output:
        alignment = "results/aligned.fasta"
    shell:
        """
        augur align \
            --sequences {input.sequences} \
            --reference-sequence {input.reference} \
            --output {output.alignment} \
            --remove-reference \
            --nthreads 1
        """


rule tree:
    message: "Building tree"
    input:
        alignment = rules.align.output.alignment
    output:
        tree = "results/tree-raw.nwk"
    params:
        method = "iqtree"
    shell:
        """
        augur tree \
            --alignment {input.alignment} \
            --output {output.tree} \
            --method {params.method} \
            --nthreads 1
        """

"""Generate a time-resolved phylogeny using TreeTime"""
rule refine:
    message:
        """
        Refining tree
          - estimate timetree
          - use {params.coalescent} coalescent timescale
          - estimate {params.date_inference} node dates
        """
    input:
        tree = rules.tree.output.tree,
        alignment = rules.align.output,
        metadata = rules.parse.output.metadata
    output:
        tree = "results/tree.nwk",
        node_data = "results/branch-lengths.json"
    params:
        coalescent = "const",
        date_inference = "marginal",
        clock_filter_iqd = 4
    shell:
        """
        augur refine \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --metadata {input.metadata} \
            --output-tree {output.tree} \
            --output-node-data {output.node_data} \
            --timetree \
            --coalescent {params.coalescent} \
            --date-confidence \
            --date-inference {params.date_inference} \
            --clock-filter-iqd {params.clock_filter_iqd}
        """

"""Reconstruct ancestral states onto each internal node using TreeTime"""
rule ancestral:
    message: "Reconstructing ancestral sequences and mutations"
    input:
        tree = rules.refine.output.tree,
        alignment = rules.align.output
    output:
        node_data = "results/nt-muts.json"
    params:
        inference = "joint"
    shell:
        """
        augur ancestral \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --output-node-data {output.node_data} \
            --inference {params.inference}\
            --keep-ambiguous
        """

rule translate:
    message: "Translating amino acid sequences"
    input:
        tree = rules.refine.output.tree,
        node_data = rules.ancestral.output.node_data,
        reference = files.reference
    output:
        node_data = "results/aa-muts.json"
    shell:
        """
        augur translate \
            --tree {input.tree} \
            --ancestral-sequences {input.node_data} \
            --reference-sequence {input.reference} \
            --output {output.node_data}
        """

rule traits:
    message: "Inferring ancestral traits for {params.columns!s}"
    input:
        tree = rules.refine.output.tree,
        metadata = rules.parse.output.metadata
    output:
        node_data = "results/traits.json",
    params:
        columns = "host order subtype region",
    shell:
        """
        augur traits \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --output {output.node_data} \
            --columns {params.columns} \
            --confidence
        """


"""This rule exports the results of the pipeline into JSON format, which is required
for visualization in auspice. To make changes to the categories of metadata
that are colored, or how the data is visualized, alter the auspice_config files"""
rule export:
    message: "Exporting data files for for auspice"
    input:
        tree = rules.refine.output.tree,
        metadata = rules.parse.output.metadata,
        node_data = [rules.refine.output.node_data,rules.traits.output.node_data,rules.ancestral.output.node_data,rules.translate.output.node_data],
        auspice_config = files.auspice_config,
	colors = files.colors
    output:
        auspice_json = "auspice/h3nx_ha.json"
    shell:
        """
        augur export v2 \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --node-data {input.node_data}\
            --auspice-config {input.auspice_config} \
            --include-root-sequence \
	    --colors {input.colors} \
            --output {output.auspice_json}
        """

rule clean:
    message: "Removing directories: {params}"
    params:
        "results ",
        "auspice"
    shell:
        "rm -rfv {params}"
