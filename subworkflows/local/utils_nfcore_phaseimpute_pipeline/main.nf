//
// Subworkflow with functionality specific to the nf-core/phaseimpute pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { UTILS_NFVALIDATION_PLUGIN } from '../../nf-core/utils_nfvalidation_plugin'
include { paramsSummaryMap          } from 'plugin/nf-validation'
include { fromSamplesheet           } from 'plugin/nf-validation'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'
include { completionEmail           } from '../../nf-core/utils_nfcore_pipeline'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { dashedLine                } from '../../nf-core/utils_nfcore_pipeline'
include { nfCoreLogo                } from '../../nf-core/utils_nfcore_pipeline'
include { imNotification            } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'
include { workflowCitation          } from '../../nf-core/utils_nfcore_pipeline'
include { GET_REGION                } from '../get_region'
include { SAMTOOLS_FAIDX            } from '../../../modules/nf-core/samtools/faidx'

/*
========================================================================================
    SUBWORKFLOW TO INITIALISE PIPELINE
========================================================================================
*/

workflow PIPELINE_INITIALISATION {

    take:
    version           // boolean: Display version and exit
    help              // boolean: Display help text
    validate_params   // boolean: Boolean whether to validate parameters against the schema at runtime
    monochrome_logs   // boolean: Do not use coloured log outputs
    nextflow_cli_args //   array: List of positional nextflow CLI args
    outdir            //  string: The output directory where the results will be saved
    input             //  string: Path to input samplesheet

    main:

    ch_versions      = Channel.empty()

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters and generate parameter summary to stdout
    //
    pre_help_text = nfCoreLogo(monochrome_logs)
    post_help_text = '\n' + workflowCitation() + '\n' + dashedLine(monochrome_logs)
    def String workflow_command = "nextflow run ${workflow.manifest.name} -profile <docker/singularity/.../institute> --input samplesheet.csv --outdir <OUTDIR>"
    UTILS_NFVALIDATION_PLUGIN (
        help,
        workflow_command,
        pre_help_text,
        post_help_text,
        validate_params,
        "nextflow_schema.json"
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE (
        nextflow_cli_args
    )
    //
    // Custom validation for pipeline parameters
    //
    validateInputParameters()

    //
    // Create fasta channel
    //
    genome = params.genome ? params.genome : file(params.fasta, checkIfExists:true).getBaseName()
    if (params.genome) {
        genome = params.genome
        ch_fasta  = Channel.of([[genome:genome], getGenomeAttribute('fasta')])
        fai       = getGenomeAttribute('fai')
        if (fai == null) {
            SAMTOOLS_FAIDX(ch_fasta, Channel.of([[], []]))
            ch_versions = ch_versions.mix(SAMTOOLS_FAIDX.out.versions.first())
            fai         = SAMTOOLS_FAIDX.out.fai.map{ it[1] }
        }
    } else if (params.fasta) {
        genome = file(params.fasta, checkIfExists:true).getBaseName()
        ch_fasta  = Channel.of([[genome:genome], file(params.fasta, checkIfExists:true)])
        if (params.fasta_fai) {
            fai = file(params.fasta_fai, checkIfExists:true)
        } else {
            SAMTOOLS_FAIDX(ch_fasta, Channel.of([[], []]))
            ch_versions = ch_versions.mix(SAMTOOLS_FAIDX.out.versions.first())
            fai         = SAMTOOLS_FAIDX.out.fai.map{ it[1] }
        }
    }
    ch_ref_gen = ch_fasta.combine(fai)

    //
    // Create map channel
    //
    ch_map   = params.map ?
        Channel.of([["map": params.map], params.map]) :
        Channel.of([[],[]])

    //
    // Create channel from input file provided through params.input
    //
    ch_input = Channel
        .fromSamplesheet("input")
        .map {
            meta, bam, bai ->
                [ meta, bam, bai ]
        }

    //
    // Create channel for panel
    //
    if (params.panel) {
        ch_panel = Channel
                .fromSamplesheet("panel")
                .map {
                    meta,vcf,index,sites,tsv,legend,phased ->
                        [ meta, vcf, index ]
                    }
    }

    //
    // Create channel from region input
    //
    if (params.input_region) {
        if (params.input_region.endsWith(".csv")) {
            println "Region file provided as input is a csv file"
            ch_regions = Channel.fromSamplesheet("input_region")
                .map{ chr, start, end -> [["chr": chr], chr + ":" + start + "-" + end]}
                .map{ metaC, region -> [metaC + ["region": region], region]}
        } else {
            println "Region file provided is a single region"
            GET_REGION (
                params.input_region,
                ch_ref_gen
            )
            ch_versions      = ch_versions.mix(GET_REGION.out.versions.first())
            ch_regions       = GET_REGION.out.regions
        }
    }

    emit:
    input         = ch_input         // [ [meta], bam, bai ]
    fasta         = ch_ref_gen       // [ [genome], fasta, fai ]
    panel         = ch_panel         // [ [panel], panel ]
    regions       = ch_regions       // [ [chr, region], region ]
    map           = ch_map           // [ [map], map ]
    versions      = ch_versions
}

/*
========================================================================================
    SUBWORKFLOW FOR PIPELINE COMPLETION
========================================================================================
*/

workflow PIPELINE_COMPLETION {

    take:
    email           //  string: email address
    email_on_fail   //  string: email address sent on pipeline failure
    plaintext_email // boolean: Send plain-text email instead of HTML
    outdir          //    path: Path to output directory where results will be published
    monochrome_logs // boolean: Disable ANSI colour codes in log output
    hook_url        //  string: hook URL for notifications
    multiqc_report  //  string: Path to MultiQC report

    main:

    summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")

    //
    // Completion email and summary
    //
    workflow.onComplete {
        if (email || email_on_fail) {
            completionEmail(summary_params, email, email_on_fail, plaintext_email, outdir, monochrome_logs, multiqc_report.toList())
        }

        completionSummary(monochrome_logs)

        if (hook_url) {
            imNotification(summary_params, hook_url)
        }
    }
}

/*
========================================================================================
    FUNCTIONS
========================================================================================
*/
//
// Check and validate pipeline parameters
//
def validateInputParameters() {
    genomeExistsError()
    // Check that only genome or fasta is provided
    assert params.genome == null || params.fasta == null, "Either --genome or --fasta must be provided"
    assert !(params.genome == null && params.fasta == null), "Only one of --genome or --fasta must be provided"

    // Check that a step is provided
    assert params.step, "A step must be provided"

    // Check that at least one tool is provided
    assert params.tools, "No tools provided"
}

//
// Validate channels from input samplesheet
//
def validateInputSamplesheet(input) {
    def (meta, bam, bai) = input
    // Check that individual IDs are unique
    // no validation for the moment
}
//
// Get attribute from genome config file e.g. fasta
//
def getGenomeAttribute(attribute) {
    if (params.genomes && params.genome && params.genomes.containsKey(params.genome)) {
        if (params.genomes[ params.genome ].containsKey(attribute)) {
            return params.genomes[ params.genome ][ attribute ]
        }
    }
    return null
}

//
// Exit pipeline if incorrect --genome key provided
//
def genomeExistsError() {
    if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
        def error_string = "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n" +
            "  Genome '${params.genome}' not found in any config files provided to the pipeline.\n" +
            "  Currently, the available genome keys are:\n" +
            "  ${params.genomes.keySet().join(", ")}\n" +
            "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        error(error_string)
    }
}

//
// Generate methods description for MultiQC
//
def toolCitationText() {
    // TODO nf-core: Optionally add in-text citation tools to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "Tool (Foo et al. 2023)" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def citation_text = [
            "Tools used in the workflow included:",
            "FastQC (Andrews 2010),",
            "MultiQC (Ewels et al. 2016)",
            "."
        ].join(' ').trim()

    return citation_text
}

def toolBibliographyText() {
    // TODO nf-core: Optionally add bibliographic entries to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "<li>Author (2023) Pub name, Journal, DOI</li>" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def reference_text = [
            "<li>Andrews S, (2010) FastQC, URL: https://www.bioinformatics.babraham.ac.uk/projects/fastqc/).</li>",
            "<li>Ewels, P., Magnusson, M., Lundin, S., & Käller, M. (2016). MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics , 32(19), 3047–3048. doi: /10.1093/bioinformatics/btw354</li>"
        ].join(' ').trim()

    return reference_text
}

def methodsDescriptionText(mqc_methods_yaml) {
    // Convert  to a named map so can be used as with familar NXF ${workflow} variable syntax in the MultiQC YML file
    def meta = [:]
    meta.workflow = workflow.toMap()
    meta["manifest_map"] = workflow.manifest.toMap()

    // Pipeline DOI
    meta["doi_text"] = meta.manifest_map.doi ? "(doi: <a href=\'https://doi.org/${meta.manifest_map.doi}\'>${meta.manifest_map.doi}</a>)" : ""
    meta["nodoi_text"] = meta.manifest_map.doi ? "": "<li>If available, make sure to update the text to include the Zenodo DOI of version of the pipeline used. </li>"

    // Tool references
    meta["tool_citations"] = ""
    meta["tool_bibliography"] = ""

    // TODO nf-core: Only uncomment below if logic in toolCitationText/toolBibliographyText has been filled!
    // meta["tool_citations"] = toolCitationText().replaceAll(", \\.", ".").replaceAll("\\. \\.", ".").replaceAll(", \\.", ".")
    // meta["tool_bibliography"] = toolBibliographyText()


    def methods_text = mqc_methods_yaml.text

    def engine =  new groovy.text.SimpleTemplateEngine()
    def description_html = engine.createTemplate(methods_text).make(meta)

    return description_html.toString()
}
