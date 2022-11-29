module simple

using CassetteOverlay, Test

@MethodTable SimpleTable;

pass = @overlaypass SimpleTable

myidentity(@nospecialize x) = x

# Run overlayed methods
@overlay SimpleTable myidentity(@nospecialize x) = 42
@test pass(myidentity, nothing) == 42
@test pass() do
    myidentity(nothing)
end == 42

# method invalidation
@overlay SimpleTable myidentity(@nospecialize x) = 0
@test pass(myidentity, nothing) == 0

# nooverlay
@overlay SimpleTable myidentity(@nospecialize x) = nooverlay(myidentity, x)
@test pass(myidentity, nothing) === nothing

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
