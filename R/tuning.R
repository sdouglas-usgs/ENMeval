#############################################
#########	TUNING FUNCTION	#############
#############################################
# THIS FUNCTION DOES SPATIALLY-INDEPENDENT EVALUATIONS
# INPUT ARGUMENTS COME FROM WRAPPER FUNCTION

tuning <- function (occ, env, bg.coords, occ.grp, bg.grp, method, maxent.args,
                    args.lab, categoricals, aggregation.factor, kfolds, bin.output,
                    clamp, rasterPreds, parallel, numCores, progbar, updateProgress,
                    userArgs) {

  noccs <- nrow(occ)
  if (method == "checkerboard1")
    group.data <- get.checkerboard1(occ, env, bg.coords,
                                    aggregation.factor)
  if (method == "checkerboard2")
    group.data <- get.checkerboard2(occ, env, bg.coords,
                                    aggregation.factor)
  if (method == "block")
    group.data <- get.block(occ, bg.coords)
  if (method == "jackknife")
    group.data <- get.jackknife(occ, bg.coords)
  if (method == "randomkfold")
    group.data <- get.randomkfold(occ, bg.coords, kfolds)
  if (method == "user")
    group.data <- get.user(occ.grp, bg.grp)
  nk <- length(unique(group.data$occ.grp))
  pres <- as.data.frame(extract(env, occ))
  bg <- as.data.frame(extract(env, bg.coords))
  if (any(is.na(colSums(pres)))){
    message("Warning: some predictors variables are NA at some occurrence points")}
  if (any(is.na(colSums(bg)))){
    message("Warning: some predictors variables are NA at some background points")}
  if (!is.null(categoricals)) {
    for (i in 1:length(categoricals)) {
      pres[, categoricals[i]] <- as.factor(pres[, categoricals[i]])
      bg[, categoricals[i]] <- as.factor(bg[, categoricals[i]])
    }
  }

  tune <- function() {
    if (length(maxent.args) > 1 & !parallel) {
      if (is.function(updateProgress)) {
        text <- paste0('Running ', args.lab[[1]][i], args.lab[[2]][i], '...')
        updateProgress(detail = text)
      } else if (progbar==T) {
        setTxtProgressBar(pb, i)
      }
    }
    if (names(pres) != names(bg)) {
      stop("Please input predictor variables as RasterStack.")
    }
    x <- rbind(pres, bg)
    p <- c(rep(1, nrow(pres)), rep(0, nrow(bg)))
    tmpfolder <- tempfile()
    full.mod <- maxent(x, p, args = c(maxent.args[[i]], userArgs),
                       factors = categoricals, path = tmpfolder)
    pred.args <- c("outputformat=raw", ifelse(clamp==TRUE, "doclamp=true", "doclamp=false"))
    if (rasterPreds==TRUE) {
      predictive.map <- predict(full.mod, env, args = pred.args)
    } else {
      predictive.map <- stack()
    }
    AUC.TEST <- double()
    AUC.DIFF <- double()
    OR10 <- double()
    ORmin <- double()

    for (k in 1:nk) {
      train.val <- pres[group.data$occ.grp != k,, drop=FALSE]
      test.val <- pres[group.data$occ.grp == k,, drop=FALSE]
      bg.val <- bg[group.data$bg.grp != k,, drop=FALSE]
      x <- rbind(train.val, bg.val)
      p <- c(rep(1, nrow(train.val)), rep(0, nrow(bg.val)))
      mod <- maxent(x, p, args = c(maxent.args[[i]], userArgs), factors = categoricals,
                    path = tmpfolder)
      AUC.TEST[k] <- evaluate(test.val, bg, mod)@auc
      AUC.DIFF[k] <- max(0, evaluate(train.val, bg, mod)@auc - AUC.TEST[k])
      p.train <- predict(mod, train.val, args = pred.args)
      p.test <- predict(mod, test.val, args = pred.args)
      if (nrow(train.val) < 10) {
        n90 <- floor(nrow(train.val) * 0.9)
      }
      else {
        n90 <- ceiling(nrow(train.val) * 0.9)
      }
      train.thr.10 <- rev(sort(p.train))[n90]
      OR10[k] <- mean(p.test < train.thr.10)
      train.thr.min <- min(p.train)
      ORmin[k] <- mean(p.test < train.thr.min)
    }
    unlink(tmpfolder, recursive = TRUE)
    stats <- c(AUC.DIFF, AUC.TEST, OR10, ORmin)
    return(list(full.mod, stats, predictive.map))
  }

  # differential behavior for parallel and default
  if (parallel == TRUE) {
    # set up parallel computing
    allCores <- detectCores()
    if (is.null(numCores)) {
      numCores <- allCores
    }
    c1 <- makeCluster(numCores)
    registerDoParallel(c1)
    numCoresUsed <- getDoParWorkers()
    message(paste("Of", allCores, "total cores using", numCoresUsed))
    #cat(paste("Of", allCores, "total cores using", numCoresUsed, "\n"))

    # log file to record status of parallel loops
    message("Running in parallel...")
    #cat("Running in parallel...\n")
    out <- foreach(i = seq_len(length(maxent.args)), .packages = c("dismo", "raster", "ENMeval")) %dopar% {
      tune()
    }
    stopCluster(c1)
  } else {
    if (progbar==T & !is.function(updateProgress)) {pb <- txtProgressBar(0, length(maxent.args), style = 3)}
    out <- list()
    for (i in 1:length(maxent.args)) {
      out[[i]] <- tune()
    }
    if(progbar==T) { close(pb) }
  }

  full.mods <- sapply(out, function(x) x[[1]])
  statsTbl <- as.data.frame(t(sapply(out, function(x) x[[2]])))
  if (rasterPreds) {
    predictive.maps <- stack(sapply(out, function(x) x[[3]]))
  } else {
    predictive.maps <- stack()
  }

  AUC.DIFF <- statsTbl[,1:nk]
  AUC.TEST <- statsTbl[,(nk+1):(2*nk)]
  OR10 <- statsTbl[,((2*nk)+1):(3*nk)]
  ORmin <- statsTbl[,((3*nk)+1):(4*nk)]
  # rename column fields
  names(AUC.DIFF) <- paste("AUC.DIFF_bin", 1:nk, sep = ".")
  Mean.AUC.DIFF <- rowMeans(AUC.DIFF)
  Var.AUC.DIFF <- corrected.var(AUC.DIFF, noccs)
  names(AUC.TEST) <- paste("AUC_bin", 1:nk, sep = ".")
  Mean.AUC <- rowMeans(AUC.TEST)
  Var.AUC <- corrected.var(AUC.TEST, noccs)
  names(OR10) <- paste("OR10_bin", 1:nk, sep = ".")
  Mean.OR10 <- rowMeans(OR10)
  Var.OR10 <- apply(OR10, 1, var)
  names(ORmin) <- paste("ORmin_bin", 1:nk, sep = ".")
  Mean.ORmin <- rowMeans(ORmin)
  Var.ORmin <- apply(ORmin, 1, var)

  # get training AUCs for each model
  full.AUC <- double()
  for (i in 1:length(full.mods)) full.AUC[i] <- full.mods[[i]]@results[5]
  # get total number of parameters
  nparm <- numeric()
  for (i in 1:length(full.mods)) nparm[i] <- get.params(full.mods[[i]])
#  if (rasterPreds==TRUE) { # this should now work even if rasterPreds==F
    aicc <- calc.aicc(nparm, occ, predictive.maps)
#  } else {
#    aicc <- rep(NaN, length(full.AUC))
#  }

  features <- args.lab[[1]]
  rm <- args.lab[[2]]
  settings <- paste(args.lab[[1]], args.lab[[2]], sep = "_")

  res <- data.frame(settings, features, rm, full.AUC, Mean.AUC,
                    Var.AUC, Mean.AUC.DIFF, Var.AUC.DIFF, Mean.OR10, Var.OR10,
                    Mean.ORmin, Var.ORmin, aicc)
  if (bin.output == TRUE) {
    res <- as.data.frame(cbind(res, AUC.TEST, AUC.DIFF, OR10, ORmin))
  }

  if (rasterPreds==TRUE) {
    names(predictive.maps) <- settings
  }
  results <- ENMevaluation(results = res, predictions = predictive.maps,
                           models = full.mods, partition.method = method, 
                           occ.pts = occ, occ.grp = group.data[[1]],
                           bg.pts = bg.coords, bg.grp = group.data[[2]])
  return(results)
}
