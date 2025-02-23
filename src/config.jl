struct Config
    user::String                    # the OS username of the user running the server
    nodes::Dict{Type,Vector{Int}}   # the pids for the nodes on the cluster
    cpus::Dict{Int,Vector{Int}}     # the indices of the cpus per node
    auth::GitHub.Authorization      # the GitHub authorization used to post statuses/reports
    secret::String                  # the GitHub secret used to validate webhooks
    trackrepo::String               # the main Julia repo tracked by the server
    reportrepo::String              # the repo to which result reports are posted
    trigger::Regex                  # a regular expression to match comments against
    admin::String                   # GitHub handle of the server administrator
    bucket::Union{Nothing,String}   # AWS bucket to upload large files too
    testmode::Bool                  # if true, jobs will run as test jobs

    function Config(user, nodes, auth, secret;
                    cpus = Dict{Int,Vector{Int}}(),
                    trackrepo = "JuliaLang/julia",
                    reportrepo = "JuliaCI/NanosoldierReports",
                    trigger =  r"\@nanosoldier\s*`runbenchmarks\(.*?\)`",
                    admin = "",
                    bucket = nothing,
                    testmode = false)
        isempty(nodes) && throw(ArgumentError("need at least one node to work on"))
        return new(user, nodes, cpus, auth, secret, trackrepo,
                   reportrepo, trigger, admin, bucket, testmode)
    end
end

# the report repository
reportrepo(config::Config) = config.reportrepo

# the local directory of the report repository
reportdir(config::Config) = joinpath(workdir, split(reportrepo(config), "/")[2])

persistdir!(path) = (isdir(path) || mkdir(path); return path)

function persistdir!(config::Config)
    persistdir!(workdir)
    if isdir(reportdir(config))
        gitreset!(reportdir(config))
    else
        gitclone!(reportrepo(config), reportdir(config), config.auth)
    end
end

function nodelog(config::Config, node, message; error=nothing)
    time = now()
    if error !== nothing
        @error "[Node $node | $time]: Encountered error: $message" exception=error
    else
        @info "[Node $node | $time]: $message"
    end
    persistdir!(workdir)
    path = joinpath(workdir, "node$(node).log")
    open(path, "a") do file
        chmod(path, 0o660)
        println(file, time, " | ", node, " | ", message)
    end
end

# the list of CPUs for a given node
mycpus(config::Config, node=getpid()) = get(config.cpus, node, 1:(Sys.CPU_THREADS-1))
