# ignoring opensuse for the time being
available_distros <- c(
  "xenial",
  "bionic",
  "focal",
  "centos7",
  "centos8"
)

#' Create a Dockerfile from an `renv.lock` file
#'
#' @param lockfile Path to an `renv.lock` file to use as an input..
#' @param FROM Docker image to start FROM Default is
#'     FROM rocker/r-base
#' @param AS The AS of the Dockerfile. Default it NULL.
#' @param distro One of "focal", "bionic", "xenial", "centos7",
#'     or "centos8". See available distributions
#'     at https://hub.docker.com/r/rstudio/r-base/.
#' @param sysreqs boolean. If `TRUE`, the Dockerfile
#'     will contain sysreq installation.
#' @param expand boolean. If `TRUE` each system requirement will have its own `RUN` line.
#' @param repos character. The URL(s) of the repositories to use for `options("repos")`.
#' @param extra_sysreqs character vector. Extra debian system requirements.
#'    Will be installed with apt-get install.
#' @importFrom utils getFromNamespace
#' @return A R6 object of class `Dockerfile`.
#' @details
#'
#' System requirements for packages are provided
#' through RStudio Package Manager via the {pak}
#' package. The install commands provided from pak
#' are added as `RUN` directives within the `Dockerfile`.
#'
#' The R version is taken from the `renv.lock` file.
#' Packages are installed using `renv::restore()` which ensures
#' that the proper package version and source is used when installed.
#'
#' @importFrom attempt map_try_catch
#' @importFrom glue glue
#' @importFrom pak pkg_system_requirements
#' @examples
#' \dontrun{
#' dock <- dock_from_renv("renv.lock", distro = "xenial")
#' dock$write("Dockerfile")
#' }
#' @export
dock_from_renv <- function(
  lockfile = "renv.lock",
  distro = "focal",
  FROM = "rocker/r-base",
  AS = NULL,
  sysreqs = TRUE,
  repos = c(CRAN = "https://cran.rstudio.com/"),
  expand = FALSE,
  extra_sysreqs = NULL
) {
  distro <- match.arg(distro, available_distros)

  lock <- getFromNamespace("lockfile", "renv")(lockfile)

  # lock$repos(CRAN = repos)
  lockfile <- basename(lockfile)

  # start the dockerfile
  R_major_minor <- lock$data()$R$Version
  dock <- Dockerfile$new(
    FROM = gen_base_image(
      distro = distro,
      r_version = R_major_minor,
      FROM = FROM
    ),
    AS = AS
  )

  distro_args <- switch(
    distro,
    centos7 = list(
      os = "centos",
      os_release = "7"
    ),
    centos8 = list(
      os = "centos",
      os_release = "8"
    ),
    xenial = list(
      os = "ubuntu",
      os_release = "16.04"
    ),
    bionic = list(
      os = "ubuntu",
      os_release = "18.04"
    ),
    focal = list(
      os = "ubuntu",
      os_release = "20.04"
    ),
    jammy = list(
      os = "ubuntu",
      os_release = "22.04"
    )
  )

  install_cmd <- switch(
    distro,
    centos7 = "yum install -y",
    centos8 = "yum install -y",
    xenial = "apt-get install -y",
    bionic = "apt-get install -y",
    focal = "apt-get install -y",
    jammy = "apt-get install -y"
  )

  update_cmd <- switch(
    distro,
    centos7 = "yum update -y",
    centos8 = "yum update -y",
    xenial = "apt-get update -y",
    bionic = "apt-get update -y",
    focal = "apt-get update -y",
    jammy = "apt-get update -y"
  )

  clean_cmd <- switch(
    distro,
    centos7 = "yum clean all && rm -rf /var/cache/yum",
    centos8 = "yum clean all && rm -rf /var/cache/yum",
    xenial = "rm -rf /var/lib/apt/lists/*",
    bionic = "rm -rf /var/lib/apt/lists/*",
    focal = "rm -rf /var/lib/apt/lists/*",
    jammy = "rm -rf /var/lib/apt/lists/*"
  )

  pkgs <- names(lock$data()$Packages)

  if (sysreqs) {

    # please wait during system requirement calculation
    cat_bullet(
      "Please wait while we compute system requirements...",
      bullet = "info",
      bullet_col = "green"
    )

    message(
      sprintf(
        "Fetching system dependencies for %s package(s) records.",
        length(pkgs)
      )
    )

    pkg_os <- lapply(
      pkgs,
      FUN = function(x) {
        c(
          list(package = x),
          distro_args
        )
      }
    )

    pkg_sysreqs <- attempt::map_try_catch(
      pkg_os,
      function(x) {
        do.call(
          pak::pkg_system_requirements,
          x
        )
      },
      .e = ~ character(0)
    )





    pkg_installs <- unique(pkg_sysreqs)

    if (length(unlist(pkg_installs)) == 0) {
      cat_bullet(
        "No sysreqs required",
        bullet = "info",
        bullet_col = "green"
      )
    }

    cat_green_tick("Done") # TODO animated version ?
  } else {
    pkg_installs <- NULL
  }

  # extra_sysreqs




  if (length(extra_sysreqs) > 0) {
    extra <- paste(
      install_cmd,
      extra_sysreqs
    )
    pkg_installs <- unique(c(pkg_installs, extra))
  }





  # compact
  if (!expand) {
    # we compact sysreqs
    pkg_installs <- compact_sysreqs(
      pkg_installs,
      update_cmd = update_cmd,
      install_cmd = install_cmd,
      clean_cmd = clean_cmd
    )

  } else {
    dock$RUN(update_cmd)
  }

  do.call(dock$RUN, list(pkg_installs))

  if (expand) {
    dock$RUN(clean_cmd)
  }

  repos_as_character <- repos_as_character(repos)
  dock$RUN("mkdir -p /usr/local/lib/R/etc/ /usr/lib/R/etc/")

  dock$RUN(
    sprintf(
      "echo \"options(renv.config.pak.enabled = TRUE, repos = %s, download.file.method = 'libcurl', Ncpus = 4)\" | tee /usr/local/lib/R/etc/Rprofile.site | tee /usr/lib/R/etc/Rprofile.site",
      repos_as_character
    )
  )

  dock$RUN("R -e 'install.packages(c(\"renv\",\"remotes\"))'")

  dock$COPY(basename(lockfile), "renv.lock")
  dock$RUN(r(renv::restore()))

  dock
}


#' Generate base image name
#'
#' Creates the base image name from the provided distro name and the R version found in the `renv.lock` file.
#'
#' @keywords internal
gen_base_image <- function(
  distro = "bionic",
  r_version = "4.0",
  FROM = "rstudio/r-base"
) {
  distro <- match.arg(distro, available_distros)

  if (FROM == "rstudio/r-base") {
    glue::glue("{FROM}:{r_version}-{distro}")
  } else {
    glue::glue("{FROM}:{r_version}")
  }
}
