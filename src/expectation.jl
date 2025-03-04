abstract type AbstractExpectationADAlgorithm end
struct NonfusedAD <: AbstractExpectationADAlgorithm end
struct PrefusedAD <: AbstractExpectationADAlgorithm
    norm_partials::Bool
end
PrefusedAD() = PrefusedAD(true)
struct PostfusedAD <: AbstractExpectationADAlgorithm
    norm_partials::Bool
end
PostfusedAD() = PostfusedAD(true)

abstract type AbstractExpectationAlgorithm <: DiffEqBase.DEAlgorithm end

"""
```julia
Koopman()
```
"""
struct Koopman{TS} <:
       AbstractExpectationAlgorithm where {TS <: AbstractExpectationADAlgorithm}
    sensealg::TS
end
Koopman() = Koopman(NonfusedAD())

"""
```julia
MonteCarlo(trajectories::Int)
```
"""
struct MonteCarlo <: AbstractExpectationAlgorithm
    trajectories::Int
end

# Builds integrand for arbitrary functions
function build_integrand(prob::ExpectationProblem, ::Koopman, ::Val{false})
    @unpack g, d = prob
    function (x, p)
        g(x, p) * pdf(d, x)
    end
end

# Builds integrand for DEProblems
function build_integrand(prob::ExpectationProblem{F}, ::Koopman,
                         ::Val{false}) where {F <: SystemMap}
    @unpack S, g, h, d = prob
    function (x, p)
        ū, p̄ = h(x, p.x[1], p.x[2])
        g(S(ū, p̄), p̄) * pdf(d, x)
    end
end

function _make_view(x::Union{Vector{T}, Adjoint{T, Vector{T}}}, i) where {T}
    @view x[i]
end

function _make_view(x, i)
    @view x[:, i]
end

function build_integrand(prob::ExpectationProblem{F}, ::Koopman,
                         ::Val{true}) where {F <: SystemMap}
    @unpack S, g, h, d = prob

    if prob.nout == 1 # TODO fix upstream in quadrature, expected sizes depend on quadrature method is requires different copying based on nout > 1
        set_result! = @inline function (dx, sol)
            dx[:] .= sol[:]
        end
    else
        set_result! = @inline function (dx, sol)
            dx .= reshape(sol[:, :], size(dx))
        end
    end

    prob_func = function (prob, i, repeat, x)  # TODO is it better to make prob/output funcs outside of integrand, then call w/ closure?
        u0, p = h((_make_view(x, i)), prob.u0, prob.p)
        remake(prob, u0 = u0, p = p)
    end

    output_func(sol, i, x) = (g(sol, sol.prob.p) * pdf(d, (_make_view(x, i))), false)

    function (dx, x, p)
        trajectories = size(x, 2)
        # TODO How to inject ensemble method in solve? currently in SystemMap, but does that make sense?
        ensprob = EnsembleProblem(S.prob; output_func = (sol, i) -> output_func(sol, i, x),
                                  prob_func = (prob, i, repeat) -> prob_func(prob, i,
                                                                             repeat, x))
        sol = solve(ensprob, S.alg, S.ensemblealg; trajectories = trajectories, S.kwargs...)
        set_result!(dx, sol)
        nothing
    end
end

function build_integrand(prob::ExpectationProblem{F}, ::Koopman,
                         ::Val{false}) where {F <: ProcessNoiseSystemMap}
    error("Out of position problems currently not supported")
end

function build_integrand(prob::ExpectationProblem{F}, ::Koopman,
                         ::Val{true}) where {F <: ProcessNoiseSystemMap}
    @unpack S, g, h, d = prob

    if prob.nout == 1 # TODO fix upstream in quadrature, expected sizes depend on quadrature method is requires different copying based on nout > 1
        set_result! = @inline function (dx, sol)
            dx[:] .= sol[:]
        end
    else
        set_result! = @inline function (dx, sol)
            dx .= reshape(sol[:, :], size(dx))
        end
    end

    prob_func = function (prob, i, repeat, x)
        Z, p = h((_make_view(x, i)), prob.u0, prob.p)
        function W(u, p, t)
            sqrt(2) *
            sum(Z[k] * sin((k - 0.5) * pi * t) / ((k - 0.5) * pi) for k in 1:length(Z))
        end
        remake(prob, p = p,
               noise = DiffEqNoiseProcess.NoiseFunction{false}(prob.tspan[1], W))
    end

    output_func(sol, i, x) = (g(sol, sol.prob.p) * pdf(d, (_make_view(x, i))), false)

    function (dx, x, p)
        trajectories = size(x, 2)
        # TODO How to inject ensemble method in solve? currently in SystemMap, but does that make sense?
        ensprob = EnsembleProblem(S.prob; output_func = (sol, i) -> output_func(sol, i, x),
                                  prob_func = (prob, i, repeat) -> prob_func(prob, i,
                                                                             repeat, x))
        sol = solve(ensprob, S.args...; trajectories = trajectories, S.kwargs...)
        set_result!(dx, sol)
        nothing
    end
end

"""
```julia
solve(exprob::ExpectationProblem, expalg::MonteCarlo)
```

Solve an `ExpectationProblem` using Monte Carlo integration.
"""
function DiffEqBase.solve(exprob::ExpectationProblem, expalg::MonteCarlo)
    params = parameters(exprob)
    dist = distribution(exprob)
    g = observable(exprob)
    ExpectationSolution(mean(g(rand(dist), params) for _ in 1:(expalg.trajectories)),
                        nothing, nothing)
end

function DiffEqBase.solve(exprob::ExpectationProblem{F},
                          expalg::MonteCarlo) where {F <: SystemMap}
    d = distribution(exprob)
    cov = input_cov(exprob)
    S = mapping(exprob)
    g = observable(exprob)

    prob_func = function (prob, i, repeat)
        u0, p = cov(rand(d), prob.u0, prob.p)
        remake(prob, u0 = u0, p = p)
    end

    output_func(sol, i) = (g(sol, sol.prob.p), false)

    monte_prob = EnsembleProblem(S.prob;
                                 output_func = output_func,
                                 prob_func = prob_func)
    sol = solve(monte_prob, S.alg, S.ensemblealg; trajectories = expalg.trajectories,
                S.kwargs...)
    ExpectationSolution(mean(sol.u), nothing, nothing)
end
function DiffEqBase.solve(exprob::ExpectationProblem{F},
                          expalg::MonteCarlo) where {F <: ProcessNoiseSystemMap}
    d = distribution(exprob)
    cov = input_cov(exprob)
    S = mapping(exprob)
    g = observable(exprob)

    prob_func = function (prob, i, repeat)
        Z, p = cov(rand(d), prob.u0, prob.p)
        function W(u, p, t)
            sqrt(2) *
            sum(Z[k] * sin((k - 0.5) * pi * t) / ((k - 0.5) * pi) for k in 1:length(Z))
        end
        remake(prob, p = p,
               noise = DiffEqNoiseProcess.NoiseFunction{false}(prob.tspan[1], W))
    end

    output_func(sol, i) = (g(sol, sol.prob.p), false)

    monte_prob = EnsembleProblem(S.prob;
                                 output_func = output_func,
                                 prob_func = prob_func)
    sol = solve(monte_prob, S.args...; trajectories = expalg.trajectories, S.kwargs...)
    ExpectationSolution(mean(sol.u), nothing, nothing)
end

"""
```julia
solve(exprob::ExpectationProblem, expalg::Koopman;
      maxiters = 1000000, batch = 0, quadalg = HCubatureJL(),
      ireltol = 1e-2, iabstol = 1e-2, kwargs...)
```

Solve an `ExpectationProblem` using Koopman integration.
"""
function DiffEqBase.solve(prob::ExpectationProblem, expalg::Koopman, args...;
                          maxiters = 1000000,
                          batch = 0,
                          quadalg = HCubatureJL(),
                          ireltol = 1e-2, iabstol = 1e-2,
                          kwargs...)
    integrand = build_integrand(prob, expalg, Val(batch > 0))
    lb, ub = extrema(prob.d)

    sol = integrate(quadalg, expalg.sensealg, integrand, lb, ub, prob.params;
                    reltol = ireltol, abstol = iabstol, maxiters = maxiters,
                    nout = prob.nout, batch = batch,
                    kwargs...)

    return ExpectationSolution(sol.u, sol.resid, sol)
end

# Integrate function to test new Adjoints, will need to roll up to Integrals.jl
function integrate(quadalg, adalg::AbstractExpectationADAlgorithm, f, lb::TB, ub::TB, p;
                   nout = 1, batch = 0,
                   kwargs...) where {TB}
    #TODO check batch iip type stability w/ IntegralProblem{XXXX}
    prob = IntegralProblem{batch > 0}(f, lb, ub, p; nout = nout, batch = batch)
    solve(prob, quadalg; kwargs...)
end

# defines adjoint via ∫∂/∂p f(x,p) dx
Zygote.@adjoint function integrate(quadalg, adalg::NonfusedAD, f::F, lb::T, ub::T,
                                   params::P;
                                   nout = 1, batch = 0, norm = norm,
                                   kwargs...) where {F, T, P}
    primal = integrate(quadalg, adalg, f, lb, ub, params;
                       norm = norm, nout = nout, batch = batch,
                       kwargs...)

    function integrate_pullbacks(Δ)
        function dfdp(x, params)
            _, back = Zygote.pullback(p -> f(x, p), params)
            back(Δ)[1]
        end
        ∂p = integrate(quadalg, adalg, dfdp, lb, ub, params;
                       norm = norm, nout = nout * length(params), batch = batch,
                       kwargs...)
        # ∂lb = -f(lb,params)  #needs correct for dim > 1
        # ∂ub = f(ub,params)
        return nothing, nothing, nothing, nothing, nothing, ∂p
    end
    primal, integrate_pullbacks
end

# defines adjoint via ∫[f(x,p; ∂/∂p f(x,p)] dx, ie it fuses the primal, post the primal calculation
# has flag to only compute quad norm with respect to only the primal in the pull-back. Gives same quadrature points as doing forwarddiff
Zygote.@adjoint function integrate(quadalg, adalg::PostfusedAD, f::F, lb::T, ub::T,
                                   params::P;
                                   nout = 1, batch = 0, norm = norm,
                                   kwargs...) where {F, T, P}
    primal = integrate(quadalg, adalg, f, lb, ub, params;
                       norm = norm, nout = nout, batch = batch,
                       kwargs...)

    _norm = adalg.norm_partials ? norm : primalnorm(nout, norm)

    function integrate_pullbacks(Δ)
        function dfdp(x, params)
            y, back = Zygote.pullback(p -> f(x, p), params)
            [y; back(Δ)[1]]   #TODO need to match proper array type? promote_type???
        end
        ∂p = integrate(quadalg, adalg, dfdp, lb, ub, params;
                       norm = _norm, nout = nout + nout * length(params), batch = batch,
                       kwargs...)
        return nothing, nothing, nothing, nothing, nothing, @view ∂p[(nout + 1):end]
    end
    primal, integrate_pullbacks
end

# Fuses primal and partials prior to pullback, I doubt this will stick around based on required system evals.
Zygote.@adjoint function integrate(quadalg, adalg::PrefusedAD, f::F, lb::T, ub::T,
                                   params::P;
                                   nout = 1, batch = 0, norm = norm,
                                   kwargs...) where {F, T, P}
    # from Seth Axen via Slack
    # Does not work w/ ArrayPartition unless with following hack
    # Base.similar(A::ArrayPartition, ::Type{T}, dims::NTuple{N,Int}) where {T,N} = similar(Array(A), T, dims)
    # TODO add ArrayPartition similar fix upstream, see https://github.com/SciML/RecursiveArrayTools.jl/issues/135
    ∂f_∂params(x, params) = only(Zygote.jacobian(p -> f(x, p), params))
    f_augmented(x, params) = [f(x, params); ∂f_∂params(x, params)...] #TODO need to match proper array type? promote_type???
    _norm = adalg.norm_partials ? norm : primalnorm(nout, norm)

    res = integrate(quadalg, adalg, f_augmented, lb, ub, params;
                    norm = _norm, nout = nout + nout * length(params), batch = batch,
                    kwargs...)
    primal = first(res)
    function integrate_pullback(Δy)
        ∂params = Δy .* conj.(@view(res[(nout + 1):end]))
        return nothing, nothing, nothing, nothing, nothing, ∂params
    end
    primal, integrate_pullback
end

# define norm function based only on primal part of fused integrand
function primalnorm(nout, fnorm)
    x -> fnorm(@view x[1:nout])
end
