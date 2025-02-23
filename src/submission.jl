mutable struct JobSubmission
    config::Config
    build::BuildRef
    statussha::String            # the SHA to send statuses to (since `build` can mutate)
    url::String                  # the URL linking to the triggering comment
    fromkind::Symbol             # `:pr`, `:review`, or `:commit`?
    prnumber::Union{Int,Nothing} # the job's PR number, if `fromkind` is `:pr` or `:review`
    func::String
    args::Vector{String}
    kwargs::Dict{Symbol,String}
end

function JobSubmission(config::Config, event::GitHub.WebhookEvent, submission_string)
    try
        build, statussha, url, fromkind, prnumber = parse_event(config, event)
        func, args, kwargs = parse_submission_string(submission_string)
        return JobSubmission(config, build, statussha, url, fromkind, prnumber, func, args, kwargs)
    catch err
        error(string("could not parse comment into job submission: ", sprint(showerror, err)))
    end
end

function Base.:(==)(a::JobSubmission, b::JobSubmission)
    if (a.prnumber === nothing) == (b.prnumber === nothing)
        same_prnumber = a.prnumber === nothing ? true : (a.prnumber == b.prnumber)
        return (same_prnumber && a.config == b.config && a.build == b.build &&
                a.statussha == b.statussha && a.url == b.url && a.fromkind == b.fromkind &&
                a.func == b.func && a.args == b.args)
    else
        return false
    end
end

function parse_event(config::Config, event::GitHub.WebhookEvent)
    if event.kind == "commit_comment"
        # A commit was commented on, and the comment contained a trigger phrase.
        # The primary repo is the location of the comment, and the primary SHA
        # is that of the commit that was commented on.
        repo = event.repository.full_name
        sha = event.payload["comment"]["commit_id"]
        url = event.payload["comment"]["html_url"]
        fromkind = :commit
        prnumber = nothing
    elseif event.kind == "pull_request_review_comment"
        # A diff was commented on, and the comment contained a trigger phrase.
        # The primary repo is the location of the head branch, and the primary
        # SHA is that of the commit associated with the diff.
        repo = event.payload["pull_request"]["head"]["repo"]["full_name"]
        sha = event.payload["comment"]["commit_id"]
        url = event.payload["comment"]["html_url"]
        fromkind = :review
        prnumber = Int(event.payload["pull_request"]["number"])
    elseif event.kind == "pull_request"
        # A PR was opened, and the description body contained a trigger phrase.
        # The primary repo is the location of the head branch, and the primary
        # SHA is that of the head commit. The PR number is provided, so that the
        # build can execute on the relevant merge commit.
        repo = event.payload["pull_request"]["head"]["repo"]["full_name"]
        sha = event.payload["pull_request"]["head"]["sha"]
        url = event.payload["pull_request"]["html_url"]
        fromkind = :pr
        prnumber = Int(event.payload["pull_request"]["number"])
    elseif event.kind == "issue_comment"
        # A comment was made in a PR, and it contained a trigger phrase. The
        # primary repo is the location of the PR's head branch, and the primary
        # SHA is that of the head commit. The PR number is provided, so that the
        # build can execute on the relevant merge commit.
        pr = GitHub.pull_request(event.repository, event.payload["issue"]["number"], auth=config.auth)
        repo = pr.head.repo.full_name
        sha = pr.head.sha
        url = event.payload["comment"]["html_url"]
        fromkind = :pr
        prnumber = Int(pr.number)
    end
    return BuildRef(repo, sha), sha, url, fromkind, prnumber
end

# `x` can only be Expr, Symbol, QuoteNode, T<:Number, or T<:AbstractString
phrase_argument(x::Union{Expr, Symbol, QuoteNode}) = string(x)
phrase_argument(x::Union{AbstractString, Number})  = repr(x)

function parse_submission_string(submission_string)
    fncall = match(r"`.*?`", submission_string).match[2:end-1]
    argind = findfirst(isequal('('), fncall)
    name = fncall[1:(argind - 1)]
    parsed_args = Meta.parse(replace(fncall[argind:end], ";" => ","))
    args, kwargs = Vector{String}(), Dict{Symbol,String}()
    if isa(parsed_args, Expr) && parsed_args.head == :tuple
        started_kwargs = false
        for x in parsed_args.args
            if isa(x, Expr) && (x.head == :kw || x.head == :(=)) && isa(x.args[1], Symbol)
                @assert !haskey(kwargs, x.args[1]) "kwargs must all be unique"
                kwargs[x.args[1]] = phrase_argument(x.args[2])
                started_kwargs = true
            else
                @assert !started_kwargs "kwargs must come after other args"
                push!(args, phrase_argument(x))
            end
        end
    else
        push!(args, phrase_argument(parsed_args))
    end
    return name, args, kwargs
end

function reply_status(sub::JobSubmission, context, state, description, url=nothing)
    if haskey(ENV, "NANOSOLDIER_DRYRUN")
        @info "Running as part of test suite, not uploading status" state description url
        return ""
    end

    if state == "failure"
        new_state = "success"
    else
        new_state = state
    end
    params = Dict("state" => new_state,
                  "context" => context,
                  "description" => snip(description, 140))
    url !== nothing && (params["target_url"] = url)
    return GitHub.create_status(sub.config.trackrepo, sub.statussha;
                                auth = sub.config.auth, params = params)
end

function reply_comment(sub::JobSubmission, message::AbstractString)
    if haskey(ENV, "NANOSOLDIER_DRYRUN")
        @info "Running as part of test suite, not replying comment" message
        return
    end

    commentplace = sub.prnumber === nothing ? sub.statussha : sub.prnumber
    commentkind = sub.fromkind == :review ? :pr : sub.fromkind
    return GitHub.create_comment(sub.config.trackrepo, commentplace, commentkind;
                                 auth = sub.config.auth, params = Dict("body" => message))
end

function upload_report_repo!(sub::JobSubmission, markdownpath, message)
    if haskey(ENV, "NANOSOLDIER_DRYRUN")
        @info "Running as part of test suite, not uploading report" message
        return ""
    end

    cfg = sub.config
    dir = reportdir(cfg)
    run(setenv(`git add -A`; dir))
    run(setenv(`git commit -m $message`; dir))
    sha = readchomp(setenv(`git rev-parse HEAD`; dir))
    run(setenv(`git pull -X ours`; dir))
    run(setenv(`git push`; dir))
    return "https://github.com/$(reportrepo(cfg))/blob/master/$(markdownpath)"
end
