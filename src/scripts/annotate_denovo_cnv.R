# de novo CNV annotation pipeline
#
# Annotate de novo CNVs from a gCNV callset.
# Usage: Rscript annotate_denovo_cnv.R CALLSET BINS PED DCRS NPROC OUTPUT
# * CALLSET - Final callset produced by gCNV pipeline
# * BINS    - Genomic bins file used by the gCNV pipeline
# * PED     - Pedigree file
# * DCRS    - List of paths, one per line, to the dCR matrices
# * NPROC   - Number of processors to use
# * OUTPUT  - Where to write the output

# Functions -------------------------------------------------------------------
# Compute the fraction of each CNV in x that is overlapped by the parental CNVs
# in y.
get_coverage <- function(x, y, relation = c("paternal", "maternal")) {
    relation <- match.arg(relation)
    ol <- findOverlaps(x, y)
    x_mcols <- mcols(x[queryHits(ol)])
    y_mcols <- mcols(y[subjectHits(ol)])
    if (relation == "paternal") {
        ol <- ol[x_mcols[["paternal_id"]] == y_mcols[["sample"]]]
    } else {
        ol <- ol[x_mcols[["maternal_id"]] == y_mcols[["sample"]]]
    }
    int <- pintersect(x[queryHits(ol)], y[subjectHits(ol)])
    cov_hit <- by(width(int) / width(x[queryHits(ol)]), queryHits(ol), sum)
    out <- double(length = length(x))
    out[as.integer(names(cov_hit))] <- cov_hit

    out
}

# Get the M, MF, MM, etc. data.frame for a suspected de novo call.
get_denovo_evidence <- function(call_info, dcr_map) {
    cid <- call_info$sample
    pid <- call_info$paternal_id
    mid <- call_info$maternal_id
    cbatch <- call_info$batch
    pbatch <- call_info$paternal_batch
    mbatch <- call_info$maternal_batch
    region <- gregion(call_info$chr, call_info$start, call_info$end)

    coord_cols <- c("chr", "start", "end")
    trio_ids <- c(cid, pid, mid)
    batches <- c(cbatch, pbatch, mbatch)
    dcr_groups <- split(trio_ids, batches)
    dcrs <- vector(mode = "list", length = length(dcr_groups))
    for (i in seq_along(dcr_groups)) {
        batch_i <- names(dcr_groups)[[i]]
        samples_i <- dcr_groups[[i]]
        dcr_paths <- gethash(dcr_map, batch_i)
        if (is.null(dcr_paths)) {
            return(regenotype(NULL))
        }
        dcr <- tryCatch(
            get_samples_dcr(
                region, dcr_paths, samples_i, include_bg = cid %in% samples_i
            ),
            error = function(cnd) NULL
        )
        if (is.null(dcr) || nrow(dcr) == 0) {
            return(regenotype(NULL))
        }

        cols <- setdiff(colnames(dcr), c(trio_ids[!trio_ids %in% samples_i], coord_cols))
        dcr_mat <- data.matrix(dcr[cols])
        rownames(dcr_mat) <- paste0(dcr$chr, ":", dcr$start, "-", dcr$end)
        dcrs[[i]] <- dcr_mat
    }

    bins <- unique(unlist(lapply(dcrs, rownames)))
    if (length(bins) == 0) {
        return(regenotype(NULL))
    }
    sample_ids <- lapply(dcrs, colnames)
    trio_dcr <- matrix(nrow = length(bins), ncol = sum(lengths(sample_ids)))
    rownames(trio_dcr) <- bins
    colnames(trio_dcr) <- unlist(sample_ids)
    for (mat in dcrs) {
        trio_dcr[rownames(mat), colnames(mat)] <- mat
    }

    bg_samples <- colnames(trio_dcr)[!colnames(trio_dcr) %in% trio_ids]
    trio_dcr <- trio_dcr[, c(trio_ids, bg_samples), drop = FALSE]

    regenotype(trio_dcr)
}

# Compute the M, MF, MM, etc. table from the trio dCR of a de novo call.
regenotype <- function(dcr) {
    default_rg <- tibble(
        M = NA_real_,
        MF = NA_real_,
        MM = NA_real_,
        MD = NA_real_,
        bins_fail = NA_integer_,
        bins = NA_integer_
    )
    if (is.null(dcr)) {
        return(default_rg)
    }

    cutoff <- 0.5
    mads <- apply(dcr, 1, mad)
    mads_fail <- sum(mads >= cutoff, na.rm = TRUE)
    if (mads_fail == length(mads)) {
        default_rg$bins_fail <- mads_fail
        default_rg$bins <- length(mads)
        return(default_rg)
    }

    means <- apply(dcr[mads < cutoff, , drop = FALSE], 2, mean, na.rm = TRUE)
    # Assume child in first column, father in second, and mother in third
    md <- min(c(abs(means[[1]] - means[[2]]), abs(means[[1]] - means[[3]])))
    rg <- tibble(
        M = means[[1]],
        MF = means[[2]],
        MM = means[[3]],
        MD = md,
        bins_fail = mads_fail,
        bins = length(mads)
    )

    rg
}

# Parse command-line arguments ------------------------------------------------
argv <- commandArgs(trailingOnly = TRUE)
if (length(argv) != 6) {
    stop("Incorrect number of arguments", call. = FALSE)
}
callset_path <- argv[[1]]
bins_path <- argv[[2]]
ped_path <- argv[[3]]
dcrs_path <- argv[[4]]
nproc <- as.integer(argv[[5]])
output <- argv[[6]]

log_info("loading libraries")
suppressPackageStartupMessages(library(gelpers))
suppressPackageStartupMessages(library(GenomicRanges))
suppressPackageStartupMessages(library(parallel))
suppressPackageStartupMessages(library(tibble))
suppressPackageStartupMessages(library(dplyr))

# Read inputs -----------------------------------------------------------------
log_info("reading callset")
raw_calls <- read_callset(callset_path) |>
    as_tibble()
is_hg19 <- any(c(as.character(1:22), "X", "Y") %in% raw_calls$chr)
log_info("reading bins")
bins <- read_gcnv_bins(bins_path, reduce = is_hg19)
log_info("reading pedigree")
ped <- read_pedigree(ped_path) |>
    as_tibble() |>
    filter(sample_id %in% raw_calls$sample) |>
    filter(paternal_id %in% raw_calls$sample) |>
    filter(maternal_id %in% raw_calls$sample)
log_info("reading dCR paths")
dcrs <- read_dcr_list(dcrs_path)

# Recalibrate offspring CNV frequency to parents' -----------------------------
log_info("making initial de novo predictions based on CNV overlap")
parent_ids <- unique(c(ped$paternal_id, ped$maternal_id))
parent_cnvs <- raw_calls |>
    filter(sample %in% parent_ids) |>
    group_by(variant_name) |>
    summarize(sc = n()) |>
    mutate(sf = sc / length(parent_ids))

raw_calls <- select(raw_calls, !c(sc, sf)) |>
    left_join(parent_cnvs, by = "variant_name", relationship = "many-to-one") |>
    mutate(sc = replace(sc, is.na(sc), 0), sf = replace(sf, is.na(sf), 0)) |>
    arrange(sample, chr, start)

# Filter calls and merge in pedigree ------------------------------------------
child_calls <- filter(
    raw_calls,
    PASS_SAMPLE & PASS_QS & sf < 0.01 & !grepl("X|Y", chr)
) |>
    inner_join(
        ped,
        by = join_by(sample == sample_id),
        multiple = "first"
    ) |>
    select(!c(family_id, sex, phenotype))

# Get preliminary de novo calls based on overlap ------------------------------
gr_c <- df_to_gr(child_calls, cnv = TRUE)

paternal_calls <- filter(raw_calls, sample %in% ped$paternal_id, !grepl("X|Y", chr))
maternal_calls <- filter(raw_calls, sample %in% ped$maternal_id, !grepl("X|Y", chr))
gr_p <- df_to_gr(paternal_calls, cnv = TRUE)
gr_m <- df_to_gr(maternal_calls, cnv = TRUE)

child_calls <- mutate(
    child_calls,
    cov_p = get_coverage(gr_c, gr_p, "paternal"),
    cov_m = get_coverage(gr_c, gr_m, "maternal")
)

gr_c_bs <- toBinSpace(gr_c, bins)
gr_p_bs <- toBinSpace(gr_p, bins)
gr_m_bs <- toBinSpace(gr_m, bins)

child_calls <- mutate(
    child_calls,
    cov_p_bs = get_coverage(gr_c_bs, gr_p_bs, "paternal"),
    cov_m_bs = get_coverage(gr_c_bs, gr_m_bs, "maternal")
)

child_calls <- child_calls |>
  mutate(
      inheritance = case_when(
          (cov_m_bs >= 0.3 | cov_m >= 0.3) & (cov_p_bs >= 0.3 | cov_p >= 0.3) ~ "biparental",
          cov_p_bs >= 0.3 | cov_p >= 0.3 ~ "paternal",
          cov_m_bs >= 0.3 | cov_m >= 0.3 ~ "maternal",
          cov_m_bs < 0.3 & cov_m < 0.3 & cov_p_bs < 0.3 & cov_p < 0.3 ~ "denovo",
          .default = "inherited"
      )
  )
dn <- filter(child_calls, inheritance == "denovo")
log_info(sprintf("found %d de novo events based on overlap", nrow(dn)))

# Gather dCR evidence ---------------------------------------------------------
batch_tbl <- select(raw_calls, sample, batch) |>
    distinct() |>
    mutate(
        paternal_id = sample,
        maternal_id = sample,
        paternal_batch = batch,
        maternal_batch = batch
  )
dn <- select(batch_tbl, paternal_id, paternal_batch) |>
    inner_join(dn, by = "paternal_id", relationship = "one-to-many")
dn <- select(batch_tbl, maternal_id, maternal_batch) |>
    inner_join(dn, by = "maternal_id", relationship = "one-to-many")

log_info("gathering dCR evidence")
rg_info <- mclapply(
    seq_len(nrow(dn)),
    \(i) get_denovo_evidence(as.list(dn[i, ]), dcrs),
    mc.cores = nproc
) |>
    bind_rows()

log_info("regenotyping")
rg_info <- rg_info |>
    mutate(
        CN = dn$CN,
        chr = dn$chr,
        inheritance = dn$inheritance,
        svtype = dn$svtype
    )

# Refine de novo calls with dCR evidence -------------------------------------
rg_info[is.na(rg_info$MF) | is.na(rg_info$MM), "inheritance"] <- "fail_miss_parents"
rg_info <- mutate(
    rg_info,
    inheritance = replace(
        inheritance,
        abs(M - CN) > 0.175 & CN <= 3,
        "fail_M"
    )
)
rg_info <- mutate(
    rg_info,
    inheritance = replace(
        inheritance,
        MD < 0.7,
        "fail_MD"
    )
)
rg_info <- mutate(
    rg_info,
    inheritance = replace(
        inheritance,
        abs(M - CN) > 0.175 & CN <= 3 & MD < 0.7,
        "fail_M_MD"
    )
)
rg_info <- mutate(
    rg_info,
    inheritance = replace(
        inheritance,
        bins_fail / bins >= 0.5 & bins < 100,
        "fail_bad_bins"
    )
)

rg_info <- mutate(
    rg_info,
    inheritance = replace(
        inheritance,
        CN > 2 & inheritance == "denovo" & (MF > 2.5 | MM > 2.5),
        "inherited"
    )
)
rg_info <- mutate(
    rg_info,
    inheritance = replace(
        inheritance,
        CN < 2 & inheritance == "denovo" & (MF < 1.5 | MM < 1.5),
        "inherited"
    )
)

rg_info$mos_dup_thresh <- NA_real_
mos_dup_idx <- with(rg_info, inheritance == "denovo" & svtype == "DUP")
mos_dup_thresh <- sapply(qnorm(0.98, 0, 0.5 / sqrt(rg_info[mos_dup_idx, ]$bins)) + 2, max, 2.1)
rg_info[mos_dup_idx, "mos_dup_thresh"] <- mos_dup_thresh

rg_info$mos_del_thresh <- NA_real_
mos_del_idx <- with(rg_info, inheritance == "denovo" & svtype == "DEL")
mos_del_thresh <- sapply(qnorm(0.98, 0, 0.5 / sqrt(rg_info[mos_del_idx, ]$bins)) * -1 + 2, min, 1.9)
rg_info[mos_del_idx, "mos_del_thresh"] <- mos_del_thresh

rg_info[which(rg_info$MF > rg_info$mos_dup_thresh), "inheritance"] <- "mosaic_father"
rg_info[which(rg_info$MM > rg_info$mos_dup_thresh), "inheritance"] <- "mosaic_mother"
rg_info[which(rg_info$MF < rg_info$mos_del_thresh), "inheritance"] <- "mosaic_father"
rg_info[which(rg_info$MM < rg_info$mos_del_thresh), "inheritance"] <- "mosaic_mother"
rg_info[which(rg_info$MF < rg_info$mos_del_thresh & rg_info$MM < rg_info$mos_del_thresh), "inheritance"] <- "mosaic_both"

# Write annotations to file --------------------------------------------------
dn$inheritance <- rg_info$inheritance
out <- inner_join(
    dn, select(ped, sample_id, family_id),
    by = join_by(sample == sample_id),
    keep = FALSE,
    multiple = "first"
)

log_info("writing output")
write.table(
  out, file = output, sep = "\t", col.names = TRUE, row.names = FALSE, quote = FALSE
)
log_info("done")
