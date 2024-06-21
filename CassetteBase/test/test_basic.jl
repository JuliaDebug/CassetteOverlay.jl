module test_basic

using Test, CassetteBase

function make_basic_generator(selfname::Symbol, fargsname::Symbol, raise::Bool)
    function basic_generator(world::UInt, source::LineNumberNode, passtype, fargtypes)
        @nospecialize passtype fargtypes
        try
            return generate_basic_src(world, source, passtype, fargtypes,
                                      selfname, fargsname; raise)
        catch err
            # internal error happened - return an expression to raise the special exception
            return generate_internalerr_ex(
                err, #=bt=#catch_backtrace(), #=context=#:basic_generator, world, source,
                #=argnames=#Core.svec(selfname, fargsname), #=spnames=#Core.svec(),
                #=metadata=#(; world, source, passtype, fargtypes))
        end
    end
end
function generate_basic_src(world::UInt, source::LineNumberNode, passtype, fargtypes,
                            selfname::Symbol, fargsname::Symbol; raise::Bool)
    @nospecialize passtype fargtypes
    tt = Base.to_tuple_type(fargtypes)
    match = Base._which(tt; raise, world)
    match === nothing && return nothing # method match failed – the fallback implementation will raise a proper MethodError
    mi = Core.Compiler.specialize_method(match)
    src = Core.Compiler.retrieve_code_info(mi, world)
    src === nothing && return nothing # code generation failed - the fallback implementation will re-raise it
    cassette_transform!(src, mi, length(fargtypes), selfname, fargsname)
    return src
end

struct BasicPass end
@eval function (pass::BasicPass)(fargs...)
    $(Expr(:meta, :generated, make_basic_generator(:pass, :fargs, #=raise=#false)))
    return first(fargs)(Base.tail(fargs)...)
end
let pass = BasicPass()
    @test pass(sin, 1) == sin(1)
    @test_throws MethodError pass("1") do x; sin(x); end
end

struct RaisePass end
@eval function (pass::RaisePass)(fargs...)
    $(Expr(:meta, :generated, make_basic_generator(:pass, :fargs, #=raise=#true)))
    return first(fargs)(Base.tail(fargs)...)
end
let pass = RaisePass()
    @test pass(sin, 1) == sin(1)
    @test_throws CassetteBase.CassetteInternalError pass("1") do x; sin(x); end
    local err
    try
        pass("1") do
            sin(x)
        end
    catch e
        err = e
    end
    @test @isdefined(err)
    @test err isa CassetteBase.CassetteInternalError
    msg = let
        buf = IOBuffer()
        showerror(buf, err)
        String(take!(buf))
    end
    @test occursin("Internal error happened in `basic_generator`:", msg)
    local err_expected
    try
        Base._which(Tuple{typeof(sin),String})
    catch e
        err_expected = e
    end
    @test @isdefined(err_expected)
    @test err.err == err_expected
    msg_expected = let
        buf = IOBuffer()
        showerror(buf, err_expected)
        String(take!(buf))
    end
    @test occursin(msg_expected, msg)
end

end # module test_basic
