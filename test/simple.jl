module simple

using CassetteOverlay, Test

@MethodTable SimpleTable;

pass = @overlaypass SimpleTable

myidentity(@nospecialize x) = x
kwifelse(x, y; cond=true) = ifelse(cond, x, y)

# run overlayed methods
@overlay SimpleTable myidentity(@nospecialize x) = 42
@test pass(myidentity, nothing) == 42
@test pass() do
    myidentity(nothing)
end == 42

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
@overlay SimpleTable myidentity(@nospecialize x) = 0
@test pass(myidentity, nothing) == 0

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

end
