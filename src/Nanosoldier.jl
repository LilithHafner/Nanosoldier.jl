module Nanosoldier

using Dates, Distributed, Printf, InteractiveUtils, Pidfile, Scratch
import GitHub, BenchmarkTools, JSON, HTTP, AWS

AWS.@service S3

const SHA_SEPARATOR = '@'
const BRANCH_SEPARATOR = ':'
const TAG_SEPARATOR = '#'
const SPECIAL_SELF = "%self"

workdir = ""

#####################
# utility functions #
#####################

snip(str, len) = str[1:min(len, end)]
snipsha(sha) = snip(sha, 7)

function gitclone!(repo, dir, auth=nothing, args::Cmd=``; user=nothing)
    if isa(auth, GitHub.OAuth2)
        url = "https://$(auth.token):x-oauth-basic@github.com/"
    elseif isa(auth, GitHub.UsernamePassAuth)
        url = "https://$(auth.username):$(auth.password)@github.com/"
    else
        auth = auth::Nothing
        url = "https://github.com/"
    end
    sudo = user === nothing ? `` : `sudo -n -u $user --`
    if auth !== nothing
        run(setenv(`$sudo mkdir -m 770 $dir`)) # hide auth from everybody
    end
    run(setenv(`$sudo git clone $args $url$repo.git $dir`))
end
gitclone!(repo, dir, args::Cmd; user=nothing) = gitclone!(repo, dir, nothing, args; user)

gitreset!(dir) = (run(setenv(`git fetch --all`; dir)); run(setenv(`git reset --hard origin/master`; dir)))

##################
# error handling #
##################

mutable struct NanosoldierError{E<:Exception} <: Exception
    url::String
    msg::String
    err::E
end

NanosoldierError(msg, err::E) where {E<:Exception} = NanosoldierError{E}("", msg, err)

function Base.show(io::IO, err::NanosoldierError)
    print(io, "NanosoldierError: ", err.msg, ": ")
    showerror(io, err.err)
end

############
# includes #
############

include("config.jl")
include("build.jl")
include("submission.jl")
include("jobs/jobs.jl")
include("server.jl")

function __init__()
    global workdir = @get_scratch!("workdir")
end

end # module
