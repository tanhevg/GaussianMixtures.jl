## stats.jl  Various ways of computing Baum Welch statistics for a GMM
## (c) 2013--2014 David A. van Leeuwen

mem=2.                          # Working memory, in Gig

function setmem(m::Float64) 
    global mem=m
end

## This function is admittedly hairy: in Octave this is much more
## efficient than a straightforward calculation.  I don't know if this
## holds for Julia.  We'd have to re-implement using loops and less
## memory.  I've done this now in several ways, it seems that the
## matrix implementation is always much faster.
 
## The shifting in dimensions (for Gaussian index k) is a nightmare.  

## stats(gmm, x) computes zero, first, and second order statistics of
## a feature file aligned to the gmm.  The statistics are ordered (ng
## * d), as by the general rule for dimension order in types.jl.
## Note: these are _uncentered_ statistics.

## you can dispatch this routine by specifying 3 parameters, 
## i.e., an unnamed explicit parameter order

function stats{T<:FloatingPoint}(gmm::GMM, x::Matrix{T}, order::Int)
    gmm.d == size(x,2) || error("dimension mismatch for data")
    gmmkind = kind(gmm)
    if gmmkind == :diag
        diagstats(gmm, x, order)
    elseif gmmkind == :full
        fullstats(gmm, x, order)
    else
        error("Unknown kind")
    end
end

## For reasons of accumulation, this function returns a tuple
## (nx, loglh, N, F [S]) which should be easy to accumulate

## The memory footprint is sizeof(T) * ((2d + 2) ng + (d + ng + 1) nx, and
## results take an additional (2d +1) ng
## This is not very efficient, since this is designed for speed, and
## we don't want to do too much in-memory yet.  
## Currently, I don't use a logsumexp implementation because of speed considerations, 
## this might turn out numerically less stable for Float32

function diagstats{T<:FloatingPoint}(gmm::GMM, x::Matrix{T}, order::Int)
    ng = gmm.n
    (nx, d) = size(x)
    prec::Matrix{T} = 1./gmm.Σ             # ng * d
    mp::Matrix{T} = gmm.μ .* prec          # mean*precision, ng * d
    ## note that we add exp(-sm2p/2) later to pxx for numerical stability
    a::Matrix{T} = gmm.w ./ (((2π)^(d/2)) * sqrt(prod(gmm.Σ,2))) # ng * 1
    sm2p::Matrix{T} = dot(mp, gmm.μ, 2)    # sum over d mean^2*precision, ng * 1
    xx = x .* x                            # nx * d
##  γ = broadcast(*, a', exp(x * mp' .- 0.5xx * prec')) # nx * ng, Likelihood per frame per Gaussian
    γ = x * mp'                            # nx * ng, nx * d * ng multiplications
    Base.BLAS.gemm!('N', 'T', -one(T)/2, xx, prec, one(T), γ)
    for j = 1:ng
        la = log(a[j]) - 0.5sm2p[j]
        for i = 1:nx
            @inbounds γ[i,j] += la
        end
    end
    for i = 1:length(γ) @inbounds γ[i] = exp(γ[i]) end
    lpf=sum(γ,2)                           # nx * 1, Likelihood per frame
    broadcast!(/, γ, γ, lpf .+ (lpf .== 0)) # nx * ng, posterior per frame per gaussian
    ## zeroth order
    N = vec(sum(γ, 1))          # ng * 1, vec()
    ## first order
    F =  γ' * x                           # ng * d, Julia has efficient a' * b
    llh = sum(log(lpf))                   # total log likeliood
    if order==1
        return (nx, llh, N, F)
    else
        ## second order
        S = γ' * xx                       # ng * d
        return (nx, llh, N, F, S)
    end
end

## this is a `slow' implementation, based on posterior()
function fullstats{T<:FloatingPoint}(gmm::GMM, x::Array{T,2}, order::Int)
    (nx, d) = size(x)
    ng = gmm.n
    γ, ll = posterior(gmm, x) # nx * ng, both
    llh = sum(logsumexp(ll .+ log(gmm.w)', 2))
    ## zeroth order
    N = vec(sum(γ, 1))
    ## first order
    F = γ' * x
    if order == 1
        return nx, llh, N, F
    end
    ## S_k = Σ_i γ _ik x_i' * x
    S = Matrix{T}[]
    γx = similar(x)
    @inbounds for k=1:ng
        #broadcast!(*, γx, γ[:,k], x) # nx * d mults
        for j = 1:d for i=1:nx
            γx[i,j] = γ[i,k]*x[i,j]
        end end
        push!(S, x' * γx)            # nx * d^2 mults
    end
    return nx, llh, N, F, S
end
    
                   
## ## reduction function for the plain results of stats(::GMM)
## function accumulate(r::Vector{Tuple})
##     res = {r[1]...}           # first stats tuple, as array
##     for i=2:length(r)
##         for j = 1:length(r[i])
##             res[j] += r[i][j]
##         end
##     end
##     tuple(res...)
## end

## split computation up in parts, either because of memory limitations
## or because of parallelization
## You dispatch this by only using 2 parameters
function stats{T<:FloatingPoint}(gmm::GMM, x::Matrix{T}; order::Int=2, parallel=false)
    parallel &= nworkers() > 1
    ng = gmm.n
    (nx, d) = size(x)
    if kind(gmm) == :diag
        bytes = sizeof(T) * ((2d +2)ng + (d + ng + 1)nx)
    elseif kind(gmm) == :full
        bytes = sizeof(T) * ((d + d^2 + 5nx + nx*d)ng + (2d + 2)nx)
    end
    blocks = iceil(bytes / (mem * (1<<30)))
    if parallel
        blocks= min(nx, max(blocks, nworkers()))
    end
    l = nx / blocks     # chop array into smaller pieces xx
    xx = Matrix{T}[x[round(i*l+1):round((i+1)l),:] for i=0:(blocks-1)]
    if parallel
        r = pmap(x->stats(gmm, x, order), xx)
        reduce(+, r)                # get +() from BigData.jl
    else
        r = stats(gmm, shift!(xx), order)
        for x in xx
            r += stats(gmm, x, order)
        end
        r
    end
end
## the reduce above needs the following
Base.zero{T}(x::Array{Matrix{T}}) = [zero(z) for z in x]
    
## This function calls stats() for the elements in d::Data, irrespective of the size, or type
function stats(gmm::GMM, d::Data; order::Int=2, parallel=false)
    if parallel
        r = dmap(x->stats(gmm, x, order=order, parallel=false), d)
        return reduce(+, r)
    else
        r = stats(gmm, d[1], order=order, parallel=false)
        for i=2:length(d)
            r += stats(gmm, d[i], order=order, parallel=false)
        end
        return r
    end
end
    
## Same, but UBM centered+scaled stats
## f and s are ng * d
function csstats{T<:FloatingPoint}(gmm::GMM, x::DataOrMatrix{T}, order::Int=2)
    kind(gmm) == :diag || error("Can only do centered and scaled stats for diag covariance")
    if order==1
        nx, llh, N, F = stats(gmm, x, order)
    else
        nx, llh, N, F, S = stats(gmm, x, order)
    end
    Nμ = N .* gmm.μ
    f = (F - Nμ) ./ gmm.Σ
    if order==1
        return(N, f)
    else
        s = (S + (Nμ-2F).*gmm.μ) ./ gmm.Σ
        return(N, f, s)
    end
end

## You can also get centered+scaled stats in a Cstats structure directly by 
## using the constructor with a GMM argument
CSstats{T<:FloatingPoint}(gmm::GMM, x::DataOrMatrix{T}) = CSstats(csstats(gmm, x, 1))

## centered stats, but not scaled by UBM covariance
## check full covariance...
function cstats{T<:FloatingPoint}(gmm::GMM, x::DataOrMatrix{T}, parallel=false)
    nx, llh, N, F, S = stats(gmm, x, order=2, parallel=parallel)
    Nμ =  N .* gmm.μ
    ## center the statistics
    gmmkind = kind(gmm)
    if gmmkind == :diag
        S += (Nμ-2F) .* gmm.μ
    elseif gmmkind == :full
        for i in 1:length(S)
            μi = gmm.μ[i,:]
            Fμi = F[i,:]' * μi
            S[i] += N[i] * μi' * μi - Fμi' - Fμi
        end
    else
        error("Unknown kind")
    end
    F -= Nμ
    return N, F, S
end

Cstats{T<:FloatingPoint}(gmm::GMM, x::DataOrMatrix{T}, parallel=false) = Cstats(cstats(gmm, x, parallel))
    
