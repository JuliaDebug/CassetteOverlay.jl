module CassetteOverlay

export @MethodTable, @overlay, @overlaypass, getpass, nonoverlay, @nonoverlay,
    AbstractBindingOverlay, Overlay

using CassetteBase

using Core: MethodTable
using Base.Experimental: @MethodTable, @overlay

abstract type OverlayPass end
function methodtable end
function getpass end
function nonoverlay end

@nospecialize
cassette_overlay_error() = error("CassetteOverlay is available via `@overlaypass` macro")
methodtable(::UInt, ::Type{<:OverlayPass}) = cassette_overlay_error()
getpass(args...; kwargs...) = cassette_overlay_error()
nonoverlay(args...; kwargs...) = cassette_overlay_error()
@specialize

macro nonoverlay(ex)
    topmod = Core.Compiler._topmod(__module__)
    f, args, kwargs = Base.destructure_callex(topmod, ex)
    out = Expr(:call, GlobalRef(@__MODULE__, :nonoverlay))
    isempty(kwargs) || push!(out.args, Expr(:parameters, kwargs...))
    push!(out.args, f)
    append!(out.args, args)
    return esc(out)
end

struct CassetteOverlayGenerator <: (@static isdefined(Core, :CachedGenerator) ? Core.CachedGenerator : Any)
    selfname::Symbol
    fargsname::Symbol
end
function (generator::CassetteOverlayGenerator)(world::UInt, source::SourceType, passtype, fargtypes)
    @nospecialize passtype fargtypes
    (; selfname, fargsname) = generator
    try
        return generate_overlay_src(world, source, passtype, fargtypes, selfname, fargsname)
    catch err
        # internal error happened - return an expression to raise the special exception
        return generate_internalerr_ex(
            err, #=bt=# catch_backtrace(), #=context=# :CassetteOverlayGenerator, world, source,
            #=argnames=# Core.svec(selfname, fargsname), #=spnames=# Core.svec(),
            #=metadata=# (; world, source, passtype, fargtypes)
        )
    end
end

global invalid_code::Vector{Any} = []

function generate_overlay_src(
        world::UInt, source::SourceType, passtype, fargtypes,
        selfname::Symbol, fargsname::Symbol
    )
    @nospecialize passtype fargtypes
    tt = Base.to_tuple_type(fargtypes)
    mt_worlds = methodtable(world, passtype)
    if mt_worlds isa Pair
        method_table, mtworlds = mt_worlds
    else
        method_table = mt_worlds
        mtworlds = nothing
    end
    match = Base._which(tt; method_table, raise = false, world)
    results = Base.Compiler.findall(tt, method_table; limit=1)
    length(results) == 1 || return nothing # method match failed – the fallback implementation will raise a proper MethodError
    match = results[1]
    match_worlds = results.valid_worlds
    mi = Core.Compiler.specialize_method(match)
    src = Core.Compiler.retrieve_code_info(mi, world)
    src === nothing && return nothing # code generation failed - the fallback implementation will re-raise it
    errors = cassette_transform!(src, mi, length(fargtypes), selfname, fargsname)
    if !isempty(errors)
        Core.println("Found invalid code:")
        for e in errors
            Core.println("- ", e)
        end
        push!(invalid_code, (world, source, passtype, fargtypes, src, selfname, fargsname))
        # TODO `return nothing` when updating the minimum compat to 1.12
    end
    if mtworlds !== nothing
        src.min_world, src.max_world = max(src.min_world, first(mtworlds)), min(src.max_world, last(mtworlds))
    end
    src.min_world, src.max_world = max(src.min_world, first(match_worlds)), min(src.max_world, last(match_worlds))
    return src
end

function get_mt_worlds(m::Module, var::Symbol, world::UInt)
    @static if VERSION ≥ v"1.12-"
        @assert isconst_at_world(m, var, world)
        mt, worlds = getglobal_at_world(m, var, world)
        return Base.Compiler.OverlayMethodTable(world, mt::MethodTable) => worlds
    else
        @assert @invokelatest isconst(M, S)
        return getglobal(M, S)::MethodTable
    end
end

macro overlaypass(args...)
    if length(args) == 1
        PassName = nothing
        method_table = args[1]
    else
        PassName, method_table = args
    end

    if !(method_table === nothing || method_table isa Symbol || Meta.isexpr(method_table, :.))
        error("Unexpected @overlaypass call")
    end

    if PassName === nothing
        PassName = esc(gensym(string(method_table)))
        decl_pass = :(struct $PassName <: $OverlayPass end)
        retval = :($PassName())
    else
        PassName = esc(PassName)
        decl_pass = :(@assert $PassName <: $OverlayPass)
        retval = nothing
    end

    nonoverlaytype = typeof(CassetteOverlay.nonoverlay)

    if method_table isa Symbol
        mthd_tbl = :(
            function $CassetteOverlay.methodtable(world::UInt, ::Type{$PassName})
                return $CassetteOverlay.get_mt_worlds($__module__, $(QuoteNode(method_table)), world)
            end
        )
    elseif Meta.isexpr(method_table, :.)
        M, S = method_table.args
        if !(M isa Symbol && S isa QuoteNode && S.value isa Symbol)
            error("Unexpected @overlaypass call")
        end
        mthd_tbl = :(
            function $CassetteOverlay.methodtable(world::UInt, ::Type{$PassName})
                return $CassetteOverlay.get_mt_worlds($(esc(M)), $S, world)
            end
        )
    else
        mthd_tbl = nothing
    end

    topblk = Expr(:toplevel)
    push!(topblk.args, decl_pass, mthd_tbl)

    # primitives
    primitives = quote
        @inline function (::$PassName)(f::Union{Core.Builtin, Core.IntrinsicFunction}, args...)
            @nospecialize f args
            return f(args...)
        end
        @inline function (self::$PassName)(::typeof(Core.Compiler.return_type), tt::DataType)
            return Core.Compiler.return_type(self, tt)
        end
        @inline function (self::$PassName)(::typeof(Core.Compiler.return_type), f, tt::DataType)
            newtt = Base.signature_type(f, tt)
            return Core.Compiler.return_type(self, newtt)
        end
        @inline function (self::$PassName)(::typeof(Core._apply_iterate), iterate, f, args...)
            @nospecialize args
            return Core.Compiler._apply_iterate(iterate, self, (f,), args...)
        end
        @inline (self::$PassName)(::typeof(getpass)) = self
    end
    append!(topblk.args, primitives.args)

    # the main code transformation pass
    mainpass = quote
        function (pass::$PassName)(fargs...)
            $(Expr(:meta, :generated, CassetteOverlayGenerator(:pass, :fargs)))
            # also include a fallback implementation that will be used when this method
            # is dynamically dispatched with `!isdispatchtuple` signatures.
            return first(fargs)(Base.tail(fargs)...)
        end
    end
    append!(topblk.args, mainpass.args)

    # nonoverlay primitives
    nonoverlaypass = quote
        @nospecialize
        @inline (pass::$PassName)(
            ::$nonoverlaytype,
            f, args...; kwargs...
        ) = f(args...; kwargs...)
        @inline (pass::$PassName)(
            ::typeof(Core.kwcall),
            kwargs::Any, ::$nonoverlaytype, fargs...
        ) = Core.kwcall(kwargs, fargs...)
        @specialize
    end
    append!(topblk.args, nonoverlaypass.args)

    push!(topblk.args, :(return $retval))

    # attach :latestworld if necessary (N.B. adding it the :toplevel block doesn't work)
    @static if VERSION ≥ v"1.12.0-DEV.1662"
        return Expr(:block, Expr(:(=), :pass, topblk), Expr(:latestworld), :pass)
    else
        return topblk
    end
end

function isconst_at_world(m::Module, var::Symbol, world::UInt)
    bpart = Base.lookup_binding_partition(world, GlobalRef(m, var))
    kind = Base.binding_kind(bpart)
    return Base.is_defined_const_binding(kind)
end

function getglobal_at_world(m::Module, var::Symbol, world::UInt)
    b = @ccall jl_get_binding(m::Any, var::Any)::Any
    bp = Base.lookup_binding_partition(world, b)
    val_ptr = @ccall jl_get_binding_value_in_world(b::Any, world::Csize_t)::Ptr{Any}
    if val_ptr == C_NULL
        throw(ccall(:jl_new_struct, Any, (Any, Any...), UndefVarError, var, world, m))
    end
    return Pair{Any, UnitRange{UInt}}(unsafe_pointer_to_objref(val_ptr), bp.min_world:bp.max_world)
end

abstract type AbstractBindingOverlay{M, S} <: OverlayPass; end
function methodtable(world::UInt, ::Type{<:AbstractBindingOverlay{M, S}}) where {M, S}
    (M isa Module && S isa Symbol) || error("Unexpected AbstractBindingOverlay type")
    return get_mt_worlds(M, S, world)
end
@overlaypass AbstractBindingOverlay nothing

struct Overlay{M, S} <: AbstractBindingOverlay{M, S} end
function Overlay(mt::MethodTable)
    @assert @invokelatest isconst(mt.module, mt.name)
    @assert mt === @invokelatest getglobal(mt.module, mt.name)
    return Overlay{mt.module, mt.name}()
end

end # module CassetteOverlay
