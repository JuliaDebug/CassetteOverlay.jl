module simple

using CassetteOverlay, Test

@MethodTable SimpleTable;

pass = @overlaypass SimpleTable

myidentity(@nospecialize x) = x
kwifelse(x, y; cond=true) = ifelse(cond, x, y)

# run overlayed methods
@overlay SimpleTable myidentity(@nospecialize x) = (@noinline; (println(devnull, "prevent inlining")); 42)
call_myidentity() = @noinline myidentity(nothing)
@test pass(call_myidentity) == 42

# kwargs
@overlay SimpleTable kwifelse(x, y; cond=true) = ifelse(cond, y, x)
let (x, y) = (0, 1)
    @test pass() do
        kwifelse(x, y)
    end == y
    @test pass() do
        kwifelse(x, y; cond=false)
    end == x
end

# method invalidation
@overlay SimpleTable myidentity(@nospecialize x) = (@noinline; (println(devnull, "prevent inlining")); 0)
@test pass(call_myidentity) == 0

# nonoverlay
@overlay SimpleTable myidentity(@nospecialize x) = nonoverlay(myidentity, x)
@test pass(myidentity, nothing) === nothing
@overlay SimpleTable myidentity(@nospecialize x) = @nonoverlay myidentity(x)
@test pass(myidentity, nothing) === nothing
@overlay SimpleTable kwifelse(x, y; cond=true) = @nonoverlay kwifelse(x, y; cond)
let (x, y) = (0, 1)
    @test pass() do
        kwifelse(x, y)
    end == x
    @test pass() do
        kwifelse(x, y; cond=false)
    end == y
end

# dynamic dispatch
global myidentity_untyped = myidentity
@test pass() do
    myidentity_untyped(nothing)
end === nothing

# variadic arguments
varargs(a, b, c...) = (a, b, c)
@test pass(varargs, 1, 2, 3) == (1,2,(3,))
@test pass(varargs, 1, 2, 3, 4) == (1,2,(3,4))

# https://github.com/JuliaDebug/CassetteOverlay.jl/issues/8
module Issue8
using CassetteOverlay
@MethodTable Issue8Table;
@overlay Issue8Table Base.identity(@nospecialize x) = nothing
end
let pass = @overlaypass Issue8.Issue8Table
    @test pass(identity, 42) == nothing
end

# JuliaDebug/CassetteOverlay#39 & JuliaDebug/CassetteOverlay#45:
# use the fallback implementation for `!isdispatchtuple` dynamic dispatches
issue39() = UnionAll(TypeVar(:T,Integer), Array{TypeVar(:T,Integer)})
@test pass() do
    issue39()
end isa UnionAll

issue45(x::UnionAll) = issue45(x.body)
issue45(x) = x
@test pass(issue45, NamedTuple) == issue45(NamedTuple)

pr46_regression(x::UnionAll) = pr46_regression(x.body)
pr46_regression(x) = myidentity(x)
@test_broken pass(fallback_regression, NamedTuple) == 42

end # module simple
