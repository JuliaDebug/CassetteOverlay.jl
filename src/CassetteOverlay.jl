module CassetteOverlay

export @MethodTable, @overlay, @overlaypass, getpass, nonoverlay, @nonoverlay,
       AbstractBindingOverlay, Overlay

using Core.IR
using Core: SimpleVector, MethodTable
using Base.Experimental: @MethodTable, @overlay

abstract type OverlayPass end
function method_table end
function getpass end
function nonoverlay end

@nospecialize
cassette_overlay_error() = error("CassetteOverlay is available via `@overlaypass` macro")
method_table(::Type{<:OverlayPass}) = cassette_overlay_error()
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

function overlay_transform!(src::CodeInfo, mi::MethodInstance, nargs::Int)
    method = mi.def::Method
    mnargs = Int(method.nargs)

    src.slotnames = Symbol[Symbol("#self#"), :fargs, src.slotnames[mnargs+1:end]...]
    src.slotflags = UInt8[ 0x00,             0x00,   src.slotflags[mnargs+1:end]...]

    code = src.code
    fargsslot = SlotNumber(2)
    precode = Any[]
    local ssaid = 0
    for i = 1:mnargs
        if method.isva && i == mnargs
            tuplecall = Expr(:call, tuple)
            for j = i:nargs
                push!(precode, Expr(:call, getfield, fargsslot, j))
                ssaid += 1
                push!(tuplecall.args, SSAValue(ssaid))
            end
            push!(precode, tuplecall)
        else
            push!(precode, Expr(:call, getfield, fargsslot, i))
        end
        ssaid += 1
    end
    prepend!(code, precode)
    @static if VERSION < v"1.12.0-DEV.173"
        prepend!(src.codelocs, [0 for i = 1:ssaid])
    else
        di = Core.Compiler.DebugInfoStream(mi, src.debuginfo, length(code))
        src.debuginfo = Core.DebugInfo(di, length(code))
    end
    prepend!(src.ssaflags, [0x00 for i = 1:ssaid])
    src.ssavaluetypes += ssaid
    if @static isdefined(Base, :__has_internal_change) && Base.__has_internal_change(v"1.12-alpha", :codeinfonargs)
        src.nargs = 2
        src.isva = true
    end

    function map_slot_number(slot::Int)
        @assert slot ≥ 1
        if 1 ≤ slot ≤ mnargs
            if method.isva && slot == mnargs
                return SSAValue(ssaid)
            else
                return SSAValue(slot)
            end
        else
            return SlotNumber(slot - mnargs + 2)
        end
    end
    map_ssa_value(id::Int) = id + ssaid
    for i = (ssaid+1:length(code))
        code[i] = transform_stmt(code[i], map_slot_number, map_ssa_value, mi.def.sig, mi.sparam_vals)
    end

    src.edges = MethodInstance[mi]
    src.method_for_inference_limit_heuristics = method

    return src
end

function transform_stmt(@nospecialize(x), map_slot_number, map_ssa_value, @nospecialize(spsig), sparams::SimpleVector)
    transform(@nospecialize x′) = transform_stmt(x′, map_slot_number, map_ssa_value, spsig, sparams)
    if isa(x, Expr)
        head = x.head
        if head === :call
            return Expr(:call, SlotNumber(1), map(transform, x.args[1:end])...)
        elseif head === :foreigncall
            arg1 = x.args[1]
            if Meta.isexpr(arg1, :call)
                # first argument of :foreigncall may be a magic tuple call, and it should be preserved
                arg1 = Expr(:call, map(transform, arg1.args)...)
            else
                arg1 = transform(x.args[1])
            end
            arg2 = @ccall jl_instantiate_type_in_env(x.args[2]::Any, spsig::Any, sparams::Ptr{Any})::Any
            arg3 = Core.svec(Any[
                    @ccall jl_instantiate_type_in_env(argt::Any, spsig::Any, sparams::Ptr{Any})::Any
                    for argt in x.args[3]::SimpleVector ]...)
            return Expr(:foreigncall, arg1, arg2, arg3, map(transform, x.args[4:end])...)
        elseif head === :enter
            return Expr(:enter, map_ssa_value(x.args[1]::Int))
        elseif head === :static_parameter
            return sparams[x.args[1]::Int]
        elseif head === :isdefined
            arg1 = x.args[1]
            if Meta.isexpr(arg1, :static_parameter)
                return 1 ≤ arg1.args[1]::Int ≤ length(sparams)
            end
        end
        return Expr(head, map(transform, x.args)...)
    elseif isa(x, GotoNode)
        return GotoNode(map_ssa_value(x.label))
    elseif isa(x, GotoIfNot)
        return GotoIfNot(transform(x.cond), map_ssa_value(x.dest))
    elseif isa(x, ReturnNode)
        return ReturnNode(transform(x.val))
    elseif isa(x, SlotNumber)
        return map_slot_number(x.id)
    elseif isa(x, NewvarNode)
        return NewvarNode(map_slot_number(x.slot.id))
    elseif isa(x, SSAValue)
        return SSAValue(map_ssa_value(x.id))
    elseif @static @isdefined(EnterNode) && isa(x, EnterNode)
        if isdefined(x, :scope)
            return EnterNode(map_ssa_value(x.catch_dest), transform(x.scope))
        else
            return EnterNode(map_ssa_value(x.catch_dest))
        end
    end
    return x
end

function overlay_generator(world::UInt, source::LineNumberNode, passtype, fargtypes)
    @nospecialize passtype fargtypes
    tt = Base.to_tuple_type(fargtypes)
    match = Base._which(tt; method_table=method_table(passtype), raise=false, world)
    match === nothing && return nothing # method match failed – the fallback implementation will raise a proper MethodError
    mi = Core.Compiler.specialize_method(match)
    src = Core.Compiler.retrieve_code_info(mi, world)
    src === nothing && return nothing # code generation failed - the fallback implementation will re-raise it
    overlay_transform!(src, mi, length(fargtypes))
    return src
end

macro overlaypass(args...)
    if length(args) == 1
        PassName = nothing
        method_table = args[1]
    else
        PassName, method_table = args
    end

    if PassName === nothing
        PassName = esc(gensym(string(method_table)))
        decl_pass = :(struct $PassName <: $OverlayPass end)
        ret = :($PassName())
    else
        PassName = esc(PassName)
        decl_pass = :(@assert $PassName <: $OverlayPass)
        ret = nothing
    end

    nonoverlaytype = typeof(CassetteOverlay.nonoverlay)

    if method_table !== :nothing
        mthd_tbl = :($CassetteOverlay.method_table(::Type{$PassName}) = $(esc(method_table)))
    else
        mthd_tbl = nothing
    end

    topblk = Expr(:toplevel)
    push!(topblk.args, decl_pass, mthd_tbl)

    # primitives
    primitives = quote
        @inline function (::$PassName)(f::Union{Core.Builtin,Core.IntrinsicFunction}, args...)
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
            $(Expr(:meta, :generated, overlay_generator))
            # also include a fallback implementation that will be used when this method
            # is dynamically dispatched with `!isdispatchtuple` signatures.
            return first(fargs)(Base.tail(fargs)...)
        end
    end
    append!(topblk.args, mainpass.args)

    # nonoverlay primitives
    nonoverlaypass = quote
        @nospecialize
        @inline function (pass::$PassName)(::$nonoverlaytype, f, args...; kwargs...)
            return f(args...; kwargs...)
        end
        @specialize

        @inline function (pass::$PassName)(::typeof(Core.kwcall), kwargs::Any, ::$nonoverlaytype, fargs...)
            @nospecialize kwargs fargs
            return Core.kwcall(kwargs, fargs...)
        end

        return $ret
    end
    append!(topblk.args, nonoverlaypass.args)

    return topblk
end

abstract type AbstractBindingOverlay{M, S} <: OverlayPass; end
function method_table(::Type{<:AbstractBindingOverlay{M, S}}) where {M, S}
    if M === nothing
        return nothing
    end
    @assert isconst(M, S)
    return getglobal(M, S)::MethodTable
end
@overlaypass AbstractBindingOverlay nothing

struct Overlay{M, S} <: AbstractBindingOverlay{M, S}; end
function Overlay(mt::MethodTable)
    @assert isconst(mt.module, mt.name)
    @assert getglobal(mt.module, mt.name) === mt
    return Overlay{mt.module, mt.name}()
end

end # module CassetteOverlay
