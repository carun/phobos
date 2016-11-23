// Written in the D programming language.

/**
This module implements a
$(HTTP erdani.org/publications/cuj-04-2002.html,discriminated union)
type (a.k.a.
$(HTTP en.wikipedia.org/wiki/Tagged_union,tagged union),
$(HTTP en.wikipedia.org/wiki/Algebraic_data_type,algebraic type)).
Such types are useful
for type-uniform binary interfaces, interfacing with scripting
languages, and comfortable exploratory programming.

Synopsis:
----
Variant a; // Must assign before use, otherwise exception ensues
// Initialize with an integer; make the type int
Variant b = 42;
assert(b.type == typeid(int));
// Peek at the value
assert(b.peek!(int) !is null && *b.peek!(int) == 42);
// Automatically convert per language rules
auto x = b.get!(real);
// Assign any other type, including other variants
a = b;
a = 3.14;
assert(a.type == typeid(double));
// Implicit conversions work just as with built-in types
assert(a < b);
// Check for convertibility
assert(!a.convertsTo!(int)); // double not convertible to int
// Strings and all other arrays are supported
a = "now I'm a string";
assert(a == "now I'm a string");
a = new int[42]; // can also assign arrays
assert(a.length == 42);
a[5] = 7;
assert(a[5] == 7);
// Can also assign class values
class Foo {}
auto foo = new Foo;
a = foo;
assert(*a.peek!(Foo) == foo); // and full type information is preserved
----

A $(LREF Variant) object can hold a value of any type, with very few
restrictions (such as `shared` types and noncopyable types). Setting the value
is as immediate as assigning to the `Variant` object. To read back the value of
the appropriate type `T`, use the $(LREF get!T) call. To query whether a
`Variant` currently holds a value of type `T`, use $(LREF peek!T). To fetch the
exact type currently held, call $(LREF type), which returns the `TypeInfo` of
the current value.

In addition to $(LREF Variant), this module also defines the $(LREF Algebraic)
type constructor. Unlike `Variant`, `Algebraic` only allows a finite set of
types, which are specified in the instantiation (e.g. $(D Algebraic!(int,
string)) may only hold an `int` or a `string`).

Credits: Reviewed by Brad Roberts. Daniel Keep provided a detailed code review
prompting the following improvements: (1) better support for arrays; (2) support
for associative arrays; (3) friendlier behavior towards the garbage collector.
Copyright: Copyright Andrei Alexandrescu 2007 - 2015.
License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors:   $(HTTP erdani.org, Andrei Alexandrescu)
Source:    $(PHOBOSSRC std/_variant.d)
*/
module std.variant;

import std.meta, std.traits, std.typecons;

/++
    Gives the $(D sizeof) the largest type given.
  +/
template maxSize(T...)
{
    static if (T.length == 1)
    {
        enum size_t maxSize = T[0].sizeof;
    }
    else
    {
        import std.algorithm.comparison : max;
        enum size_t maxSize = max(T[0].sizeof, maxSize!(T[1 .. $]));
    }
}

struct This;

private alias This2Variant(V, T...) = AliasSeq!(ReplaceType!(This, V, T));

/**
 * Back-end type seldom used directly by user
 * code. Two commonly-used types using $(D VariantN) are:
 *
 * $(OL $(LI $(LREF Algebraic): A closed discriminated union with a
 * limited type universe (e.g., $(D Algebraic!(int, double,
 * string)) only accepts these three types and rejects anything
 * else).) $(LI $(LREF Variant): An open discriminated union allowing an
 * unbounded set of types. If any of the types in the $(D Variant)
 * are larger than the largest built-in type, they will automatically
 * be boxed. This means that even large types will only be the size
 * of a pointer within the $(D Variant), but this also implies some
 * overhead. $(D Variant) can accommodate all primitive types and
 * all user-defined types.))
 *
 * Both $(D Algebraic) and $(D Variant) share $(D
 * VariantN)'s interface. (See their respective documentations below.)
 *
 * $(D VariantN) is a discriminated union type parameterized
 * with the largest size of the types stored ($(D maxDataSize))
 * and with the list of allowed types ($(D AllowedTypes)). If
 * the list is empty, then any type up of size up to $(D
 * maxDataSize) (rounded up for alignment) can be stored in a
 * $(D VariantN) object without being boxed (types larger
 * than this will be boxed).
 *
 */
struct VariantN(size_t maxDataSize, AllowedTypesParam...)
{
    /**
    The list of allowed types. If empty, any type is allowed.
    */
    alias AllowedTypes = This2Variant!(VariantN, AllowedTypesParam);

private:
    // Compute the largest practical size from maxDataSize
    struct SizeChecker
    {
        int function() fptr;
        ubyte[maxDataSize] data;
    }
    enum size = SizeChecker.sizeof - (int function()).sizeof;

    /** Tells whether a type $(D T) is statically allowed for
     * storage inside a $(D VariantN) object by looking
     * $(D T) up in $(D AllowedTypes).
     */
    public template allowed(T)
    {
        enum bool allowed
            = is(T == VariantN)
            ||
            //T.sizeof <= size &&
            (AllowedTypes.length == 0 || staticIndexOf!(T, AllowedTypes) >= 0);
    }

    // Each internal operation is encoded with an identifier. See
    // the "handler" function below.
    enum OpID { getTypeInfo, get, compare, equals, testConversion, toString,
            index, indexAssign, catAssign, copyOut, length,
            apply, postblit, destruct }

    // state
    ptrdiff_t function(OpID selector, ubyte[size]* store, void* data) fptr
        = &handler!(void);
    union
    {
        ubyte[size] store;
        // conservatively mark the region as pointers
        static if (size >= (void*).sizeof)
            void*[size / (void*).sizeof] p;
    }

    // internals
    // Handler for an uninitialized value
    static ptrdiff_t handler(A : void)(OpID selector, ubyte[size]*, void* parm)
    {
        switch (selector)
        {
        case OpID.getTypeInfo:
            *cast(TypeInfo *) parm = typeid(A);
            break;
        case OpID.copyOut:
            auto target = cast(VariantN *) parm;
            target.fptr = &handler!(A);
            // no need to copy the data (it's garbage)
            break;
        case OpID.compare:
        case OpID.equals:
            auto rhs = cast(const VariantN *) parm;
            return rhs.peek!(A)
                ? 0 // all uninitialized are equal
                : ptrdiff_t.min; // uninitialized variant is not comparable otherwise
        case OpID.toString:
            string * target = cast(string*) parm;
            *target = "<Uninitialized VariantN>";
            break;
        case OpID.postblit:
        case OpID.destruct:
            break;
        case OpID.get:
        case OpID.testConversion:
        case OpID.index:
        case OpID.indexAssign:
        case OpID.catAssign:
        case OpID.length:
            throw new VariantException(
                "Attempt to use an uninitialized VariantN");
        default: assert(false, "Invalid OpID");
        }
        return 0;
    }

    // Handler for all of a type's operations
    static ptrdiff_t handler(A)(OpID selector, ubyte[size]* pStore, void* parm)
    {
        import std.conv : to;
        static A* getPtr(void* untyped)
        {
            if (untyped)
            {
                static if (A.sizeof <= size)
                    return cast(A*) untyped;
                else
                    return *cast(A**) untyped;
            }
            return null;
        }

        static ptrdiff_t compare(A* rhsPA, A* zis, OpID selector)
        {
            static if (is(typeof(*rhsPA == *zis)))
            {
                if (*rhsPA == *zis)
                {
                    return 0;
                }
                static if (is(typeof(*zis < *rhsPA)))
                {
                    // Many types (such as any using the default Object opCmp)
                    // will throw on an invalid opCmp, so do it only
                    // if the caller requests it.
                    if (selector == OpID.compare)
                        return *zis < *rhsPA ? -1 : 1;
                    else
                        return ptrdiff_t.min;
                }
                else
                {
                    // Not equal, and type does not support ordering
                    // comparisons.
                    return ptrdiff_t.min;
                }
            }
            else
            {
                // Type does not support comparisons at all.
                return ptrdiff_t.min;
            }
        }

        auto zis = getPtr(pStore);
        // Input: TypeInfo object
        // Output: target points to a copy of *me, if me was not null
        // Returns: true iff the A can be converted to the type represented
        // by the incoming TypeInfo
        static bool tryPutting(A* src, TypeInfo targetType, void* target)
        {
            alias UA = Unqual!A;
            alias MutaTypes = AliasSeq!(UA, ImplicitConversionTargets!UA);
            alias ConstTypes = staticMap!(ConstOf, MutaTypes);
            alias SharedTypes = staticMap!(SharedOf, MutaTypes);
            alias SharedConstTypes = staticMap!(SharedConstOf, MutaTypes);
            alias ImmuTypes  = staticMap!(ImmutableOf, MutaTypes);

            static if (is(A == immutable))
                alias AllTypes = AliasSeq!(ImmuTypes, ConstTypes, SharedConstTypes);
            else static if (is(A == shared))
            {
                static if (is(A == const))
                    alias AllTypes = SharedConstTypes;
                else
                    alias AllTypes = AliasSeq!(SharedTypes, SharedConstTypes);
            }
            else
            {
                static if (is(A == const))
                    alias AllTypes = ConstTypes;
                else
                    alias AllTypes = AliasSeq!(MutaTypes, ConstTypes);
            }

            foreach (T ; AllTypes)
            {
                if (targetType != typeid(T))
                    continue;

                static if (is(typeof(*cast(T*) target = *src)) ||
                           is(T ==        const(U), U) ||
                           is(T ==       shared(U), U) ||
                           is(T == shared const(U), U) ||
                           is(T ==    immutable(U), U))
                {
                    import std.conv : emplaceRef;

                    auto zat = cast(T*) target;
                    if (src)
                    {
                        static if (T.sizeof > 0)
                            assert(target, "target must be non-null");

                        emplaceRef(*cast(Unqual!T*) zat, *cast(UA*) src);
                    }
                }
                else
                {
                    // type T is not constructible from A
                    if (src)
                        assert(false, A.stringof);
                }
                return true;
            }
            return false;
        }

        switch (selector)
        {
        case OpID.getTypeInfo:
            *cast(TypeInfo *) parm = typeid(A);
            break;
        case OpID.copyOut:
            auto target = cast(VariantN *) parm;
            assert(target);

            static if (target.size < A.sizeof)
            {
                if (target.type.tsize < A.sizeof)
                    *cast(A**)&target.store = new A;
            }
            tryPutting(zis, typeid(A), cast(void*) getPtr(&target.store))
                || assert(false);
            target.fptr = &handler!(A);
            break;
        case OpID.get:
            auto t = * cast(Tuple!(TypeInfo, void*)*) parm;
            return !tryPutting(zis, t[0], t[1]);
        case OpID.testConversion:
            return !tryPutting(null, *cast(TypeInfo*) parm, null);
        case OpID.compare:
        case OpID.equals:
            auto rhsP = cast(VariantN *) parm;
            auto rhsType = rhsP.type;
            // Are we the same?
            if (rhsType == typeid(A))
            {
                // cool! Same type!
                auto rhsPA = getPtr(&rhsP.store);
                return compare(rhsPA, zis, selector);
            }
            else if (rhsType == typeid(void))
            {
                // No support for ordering comparisons with
                // uninitialized vars
                return ptrdiff_t.min;
            }
            VariantN temp;
            // Do I convert to rhs?
            if (tryPutting(zis, rhsType, &temp.store))
            {
                // cool, I do; temp's store contains my data in rhs's type!
                // also fix up its fptr
                temp.fptr = rhsP.fptr;
                // now lhsWithRhsType is a full-blown VariantN of rhs's type
                if (selector == OpID.compare)
                    return temp.opCmp(*rhsP);
                else
                    return temp.opEquals(*rhsP) ? 0 : 1;
            }
            // Does rhs convert to zis?
            auto t = tuple(typeid(A), &temp.store);
            if (rhsP.fptr(OpID.get, &rhsP.store, &t) == 0)
            {
                // cool! Now temp has rhs in my type!
                auto rhsPA = getPtr(&temp.store);
                return compare(rhsPA, zis, selector);
            }
            return ptrdiff_t.min; // dunno
        case OpID.toString:
            auto target = cast(string*) parm;
            static if (is(typeof(to!(string)(*zis))))
            {
                *target = to!(string)(*zis);
                break;
            }
            // TODO: The following test evaluates to true for shared objects.
            //       Use __traits for now until this is sorted out.
            // else static if (is(typeof((*zis).toString)))
            else static if (__traits(compiles, {(*zis).toString();}))
            {
                *target = (*zis).toString();
                break;
            }
            else
            {
                throw new VariantException(typeid(A), typeid(string));
            }

        case OpID.index:
            auto result = cast(Variant*) parm;
            static if (isArray!(A) && !is(Unqual!(typeof(A.init[0])) == void))
            {
                // array type; input and output are the same VariantN
                size_t index = result.convertsTo!(int)
                    ? result.get!(int) : result.get!(size_t);
                *result = (*zis)[index];
                break;
            }
            else static if (isAssociativeArray!(A))
            {
                *result = (*zis)[result.get!(typeof(A.init.keys[0]))];
                break;
            }
            else
            {
                throw new VariantException(typeid(A), result[0].type);
            }

        case OpID.indexAssign:
            // array type; result comes first, index comes second
            auto args = cast(Variant*) parm;
            static if (isArray!(A) && is(typeof((*zis)[0] = (*zis)[0])))
            {
                size_t index = args[1].convertsTo!(int)
                    ? args[1].get!(int) : args[1].get!(size_t);
                (*zis)[index] = args[0].get!(typeof((*zis)[0]));
                break;
            }
            else static if (isAssociativeArray!(A))
            {
                (*zis)[args[1].get!(typeof(A.init.keys[0]))]
                    = args[0].get!(typeof(A.init.values[0]));
                break;
            }
            else
            {
                throw new VariantException(typeid(A), args[0].type);
            }

        case OpID.catAssign:
            static if (!is(Unqual!(typeof((*zis)[0])) == void) && is(typeof((*zis)[0])) && is(typeof((*zis) ~= *zis)))
            {
                // array type; parm is the element to append
                auto arg = cast(Variant*) parm;
                alias E = typeof((*zis)[0]);
                if (arg[0].convertsTo!(E))
                {
                    // append one element to the array
                    (*zis) ~= [ arg[0].get!(E) ];
                }
                else
                {
                    // append a whole array to the array
                    (*zis) ~= arg[0].get!(A);
                }
                break;
            }
            else
            {
                throw new VariantException(typeid(A), typeid(void[]));
            }

        case OpID.length:
            static if (isArray!(A) || isAssociativeArray!(A))
            {
                return zis.length;
            }
            else
            {
                throw new VariantException(typeid(A), typeid(void[]));
            }

        case OpID.apply:
            static if (!isFunctionPointer!A && !isDelegate!A)
            {
                import std.conv : text;
                import std.exception : enforce;
                enforce(0, text("Cannot apply `()' to a value of type `",
                                A.stringof, "'."));
            }
            else
            {
                import std.conv : text;
                import std.exception : enforce;
                alias ParamTypes = Parameters!A;
                auto p = cast(Variant*) parm;
                auto argCount = p.get!size_t;
                // To assign the tuple we need to use the unqualified version,
                // otherwise we run into issues such as with const values.
                // We still get the actual type from the Variant though
                // to ensure that we retain const correctness.
                Tuple!(staticMap!(Unqual, ParamTypes)) t;
                enforce(t.length == argCount,
                        text("Argument count mismatch: ",
                             A.stringof, " expects ", t.length,
                             " argument(s), not ", argCount, "."));
                auto variantArgs = p[1 .. argCount + 1];
                foreach (i, T; ParamTypes)
                {
                    t[i] = cast()variantArgs[i].get!T;
                }

                auto args = cast(Tuple!(ParamTypes))t;
                static if (is(ReturnType!A == void))
                {
                    (*zis)(args.expand);
                    *p = Variant.init; // void returns uninitialized Variant.
                }
                else
                {
                    *p = (*zis)(args.expand);
                }
            }
            break;

        case OpID.postblit:
            static if (hasElaborateCopyConstructor!A)
            {
                typeid(A).postblit(zis);
            }
            break;

        case OpID.destruct:
            static if (hasElaborateDestructor!A)
            {
                typeid(A).destroy(zis);
            }
            break;

        default: assert(false);
        }
        return 0;
    }

public:
    /** Constructs a $(D VariantN) value given an argument of a
     * generic type. Statically rejects disallowed types.
     */

    this(T)(T value)
    {
        static assert(allowed!(T), "Cannot store a " ~ T.stringof
            ~ " in a " ~ VariantN.stringof);
        opAssign(value);
    }

    /// Allows assignment from a subset algebraic type
    this(T : VariantN!(tsize, Types), size_t tsize, Types...)(T value)
        if (!is(T : VariantN) && Types.length > 0 && allSatisfy!(allowed, Types))
    {
        opAssign(value);
    }

    static if (!AllowedTypes.length || anySatisfy!(hasElaborateCopyConstructor, AllowedTypes))
    {
        this(this)
        {
            fptr(OpID.postblit, &store, null);
        }
    }

    static if (!AllowedTypes.length || anySatisfy!(hasElaborateDestructor, AllowedTypes))
    {
        ~this()
        {
            fptr(OpID.destruct, &store, null);
        }
    }

    /** Assigns a $(D VariantN) from a generic
     * argument. Statically rejects disallowed types. */

    VariantN opAssign(T)(T rhs)
    {
        //writeln(typeid(rhs));
        static assert(allowed!(T), "Cannot store a " ~ T.stringof
            ~ " in a " ~ VariantN.stringof ~ ". Valid types are "
                ~ AllowedTypes.stringof);

        static if (is(T : VariantN))
        {
            rhs.fptr(OpID.copyOut, &rhs.store, &this);
        }
        else static if (is(T : const(VariantN)))
        {
            static assert(false,
                    "Assigning Variant objects from const Variant"~
                    " objects is currently not supported.");
        }
        else
        {
            static if (!AllowedTypes.length || anySatisfy!(hasElaborateDestructor, AllowedTypes))
            {
                // Assignment should destruct previous value
                fptr(OpID.destruct, &store, null);
            }

            static if (T.sizeof <= size)
            {
                import core.stdc.string : memcpy;
                // If T is a class we're only copying the reference, so it
                // should be safe to cast away shared so the memcpy will work.
                //
                // TODO: If a shared class has an atomic reference then using
                //       an atomic load may be more correct.  Just make sure
                //       to use the fastest approach for the load op.
                static if (is(T == class) && is(T == shared))
                    memcpy(&store, cast(const(void*)) &rhs, rhs.sizeof);
                else
                    memcpy(&store, &rhs, rhs.sizeof);
                static if (hasElaborateCopyConstructor!T)
                {
                    typeid(T).postblit(&store);
                }
            }
            else
            {
                import core.stdc.string : memcpy;
                static if (__traits(compiles, {new T(T.init);}))
                {
                    auto p = new T(rhs);
                }
                else
                {
                    auto p = new T;
                    *p = rhs;
                }
                memcpy(&store, &p, p.sizeof);
            }
            fptr = &handler!(T);
        }
        return this;
    }

    // Allow assignment from another variant which is a subset of this one
    VariantN opAssign(T : VariantN!(tsize, Types), size_t tsize, Types...)(T rhs)
        if (!is(T : VariantN) && Types.length > 0 && allSatisfy!(allowed, Types))
    {
        // discover which type rhs is actually storing
        foreach (V; T.AllowedTypes)
            if (rhs.type == typeid(V))
                return this = rhs.get!V;
        assert(0, T.AllowedTypes.stringof);
    }


    Variant opCall(P...)(auto ref P params)
    {
        Variant[P.length + 1] pack;
        pack[0] = P.length;
        foreach (i, _; params)
        {
            pack[i + 1] = params[i];
        }
        fptr(OpID.apply, &store, &pack);
        return pack[0];
    }

    /** Returns true if and only if the $(D VariantN) object
     * holds a valid value (has been initialized with, or assigned
     * from, a valid value).
     */
    @property bool hasValue() const pure nothrow
    {
        // @@@BUG@@@ in compiler, the cast shouldn't be needed
        return cast(typeof(&handler!(void))) fptr != &handler!(void);
    }

    ///
    unittest
    {
        Variant a;
        assert(!a.hasValue);
        Variant b;
        a = b;
        assert(!a.hasValue); // still no value
        a = 5;
        assert(a.hasValue);
    }

    /**
     * If the $(D VariantN) object holds a value of the
     * $(I exact) type $(D T), returns a pointer to that
     * value. Otherwise, returns $(D null). In cases
     * where $(D T) is statically disallowed, $(D
     * peek) will not compile.
     */
    @property inout(T)* peek(T)() inout
    {
        static if (!is(T == void))
            static assert(allowed!(T), "Cannot store a " ~ T.stringof
                    ~ " in a " ~ VariantN.stringof);
        if (type != typeid(T))
            return null;
        static if (T.sizeof <= size)
            return cast(inout T*)&store;
        else
            return *cast(inout T**)&store;
    }

    ///
    unittest
    {
        Variant a = 5;
        auto b = a.peek!(int);
        assert(b !is null);
        *b = 6;
        assert(a == 6);
    }

    /**
     * Returns the $(D typeid) of the currently held value.
     */

    @property TypeInfo type() const nothrow @trusted
    {
        scope(failure) assert(0);

        TypeInfo result;
        fptr(OpID.getTypeInfo, null, &result);
        return result;
    }

    /**
     * Returns $(D true) if and only if the $(D VariantN)
     * object holds an object implicitly convertible to type $(D
     * U). Implicit convertibility is defined as per
     * $(REF_ALTTEXT ImplicitConversionTargets, ImplicitConversionTargets, std,traits).
     */

    @property bool convertsTo(T)() const
    {
        TypeInfo info = typeid(T);
        return fptr(OpID.testConversion, null, &info) == 0;
    }

    /**
    Returns the value stored in the `VariantN` object, either by specifying the
    needed type or the index in the list of allowed types. The latter overload
    only applies to bounded variants (e.g. $(LREF Algebraic)).

    Params:
    T = The requested type. The currently stored value must implicitly convert
    to the requested type, in fact `DecayStaticToDynamicArray!T`. If an
    implicit conversion is not possible, throws a `VariantException`.
    index = The index of the type among `AllowedTypesParam`, zero-based.
     */
    @property inout(T) get(T)() inout
    {
        inout(T) result = void;
        static if (is(T == shared))
            alias R = shared Unqual!T;
        else
            alias R = Unqual!T;
        auto buf = tuple(typeid(T), cast(R*)&result);

        if (fptr(OpID.get, cast(ubyte[size]*) &store, &buf))
        {
            throw new VariantException(type, typeid(T));
        }
        return result;
    }

    /// Ditto
    @property auto get(uint index)() inout
    if (index < AllowedTypes.length)
    {
        foreach (i, T; AllowedTypes)
        {
            static if (index == i) return get!T;
        }
        assert(0);
    }

    /**
     * Returns the value stored in the $(D VariantN) object,
     * explicitly converted (coerced) to the requested type $(D
     * T). If $(D T) is a string type, the value is formatted as
     * a string. If the $(D VariantN) object is a string, a
     * parse of the string to type $(D T) is attempted. If a
     * conversion is not possible, throws a $(D
     * VariantException).
     */

    @property T coerce(T)()
    {
        import std.conv : to, text;
        static if (isNumeric!T || isBoolean!T)
        {
            if (convertsTo!real)
            {
                // maybe optimize this fella; handle ints separately
                return to!T(get!real);
            }
            else if (convertsTo!(const(char)[]))
            {
                return to!T(get!(const(char)[]));
            }
            // I'm not sure why this doesn't convert to const(char),
            // but apparently it doesn't (probably a deeper bug).
            //
            // Until that is fixed, this quick addition keeps a common
            // function working. "10".coerce!int ought to work.
            else if (convertsTo!(immutable(char)[]))
            {
                return to!T(get!(immutable(char)[]));
            }
            else
            {
                import std.exception : enforce;
                enforce(false, text("Type ", type, " does not convert to ",
                                typeid(T)));
                assert(0);
            }
        }
        else static if (is(T : Object))
        {
            return to!(T)(get!(Object));
        }
        else static if (isSomeString!(T))
        {
            return to!(T)(toString());
        }
        else
        {
            // Fix for bug 1649
            static assert(false, "unsupported type for coercion");
        }
    }

    /**
     * Formats the stored value as a string.
     */

    string toString()
    {
        string result;
        fptr(OpID.toString, &store, &result) == 0 || assert(false);
        return result;
    }

    /**
     * Comparison for equality used by the "==" and "!="  operators.
     */

    // returns 1 if the two are equal
    bool opEquals(T)(auto ref T rhs) const
    {
        static if (is(Unqual!T == VariantN))
            alias temp = rhs;
        else
            auto temp = VariantN(rhs);
        return !fptr(OpID.equals, cast(ubyte[size]*) &store,
                     cast(void*) &temp);
    }

    // workaround for bug 10567 fix
    int opCmp(ref const VariantN rhs) const
    {
        return (cast()this).opCmp!(VariantN)(cast()rhs);
    }

    /**
     * Ordering comparison used by the "<", "<=", ">", and ">="
     * operators. In case comparison is not sensible between the held
     * value and $(D rhs), an exception is thrown.
     */

    int opCmp(T)(T rhs)
    {
        static if (is(T == VariantN))
            alias temp = rhs;
        else
            auto temp = VariantN(rhs);
        auto result = fptr(OpID.compare, &store, &temp);
        if (result == ptrdiff_t.min)
        {
            throw new VariantException(type, temp.type);
        }

        assert(result >= -1 && result <= 1);  // Should be true for opCmp.
        return cast(int) result;
    }

    /**
     * Computes the hash of the held value.
     */

    size_t toHash() const nothrow @safe
    {
        return type.getHash(&store);
    }

    private VariantN opArithmetic(T, string op)(T other)
    {
        static if (isInstanceOf!(.VariantN, T))
        {
            string tryUseType(string tp)
            {
                import std.format : format;
                return q{
                    static if (allowed!%1$s && T.allowed!%1$s)
                        if (convertsTo!%1$s && other.convertsTo!%1$s)
                            return VariantN(get!%1$s %2$s other.get!%1$s);
                }.format(tp, op);
            }

            mixin(tryUseType("uint"));
            mixin(tryUseType("int"));
            mixin(tryUseType("ulong"));
            mixin(tryUseType("long"));
            mixin(tryUseType("float"));
            mixin(tryUseType("double"));
            mixin(tryUseType("real"));
        }
        else
        {
            static if (allowed!T)
                if (auto pv = peek!T) return VariantN(mixin("*pv " ~ op ~ " other"));
            static if (allowed!uint && is(typeof(T.max) : uint) && isUnsigned!T)
                if (convertsTo!uint) return VariantN(mixin("get!(uint) " ~ op ~ " other"));
            static if (allowed!int && is(typeof(T.max) : int) && !isUnsigned!T)
                if (convertsTo!int) return VariantN(mixin("get!(int) " ~ op ~ " other"));
            static if (allowed!ulong && is(typeof(T.max) : ulong) && isUnsigned!T)
                if (convertsTo!ulong) return VariantN(mixin("get!(ulong) " ~ op ~ " other"));
            static if (allowed!long && is(typeof(T.max) : long) && !isUnsigned!T)
                if (convertsTo!long) return VariantN(mixin("get!(long) " ~ op ~ " other"));
            static if (allowed!float && is(T : float))
                if (convertsTo!float) return VariantN(mixin("get!(float) " ~ op ~ " other"));
            static if (allowed!double && is(T : double))
                if (convertsTo!double) return VariantN(mixin("get!(double) " ~ op ~ " other"));
            static if (allowed!real && is (T : real))
                if (convertsTo!real) return VariantN(mixin("get!(real) " ~ op ~ " other"));
        }

        throw new VariantException("No possible match found for VariantN "~op~" "~T.stringof);
    }

    private VariantN opLogic(T, string op)(T other)
    {
        VariantN result;
        static if (is(T == VariantN))
        {
            if (convertsTo!(uint) && other.convertsTo!(uint))
                result = mixin("get!(uint) " ~ op ~ " other.get!(uint)");
            else if (convertsTo!(int) && other.convertsTo!(int))
                result = mixin("get!(int) " ~ op ~ " other.get!(int)");
            else if (convertsTo!(ulong) && other.convertsTo!(ulong))
                result = mixin("get!(ulong) " ~ op ~ " other.get!(ulong)");
            else
                result = mixin("get!(long) " ~ op ~ " other.get!(long)");
        }
        else
        {
            if (is(typeof(T.max) : uint) && T.min == 0 && convertsTo!(uint))
                result = mixin("get!(uint) " ~ op ~ " other");
            else if (is(typeof(T.max) : int) && T.min < 0 && convertsTo!(int))
                result = mixin("get!(int) " ~ op ~ " other");
            else if (is(typeof(T.max) : ulong) && T.min == 0
                     && convertsTo!(ulong))
                result = mixin("get!(ulong) " ~ op ~ " other");
            else
                result = mixin("get!(long) " ~ op ~ " other");
        }
        return result;
    }

    /**
     * Arithmetic between $(D VariantN) objects and numeric
     * values. All arithmetic operations return a $(D VariantN)
     * object typed depending on the types of both values
     * involved. The conversion rules mimic D's built-in rules for
     * arithmetic conversions.
     */

    // Adapted from http://www.prowiki.org/wiki4d/wiki.cgi?DanielKeep/Variant
    // arithmetic
    VariantN opAdd(T)(T rhs) { return opArithmetic!(T, "+")(rhs); }
    ///ditto
    VariantN opSub(T)(T rhs) { return opArithmetic!(T, "-")(rhs); }

    // Commenteed all _r versions for now because of ambiguities
    // arising when two Variants are used

    // ///ditto
    // VariantN opSub_r(T)(T lhs)
    // {
    //     return VariantN(lhs).opArithmetic!(VariantN, "-")(this);
    // }
    ///ditto
    VariantN opMul(T)(T rhs) { return opArithmetic!(T, "*")(rhs); }
    ///ditto
    VariantN opDiv(T)(T rhs) { return opArithmetic!(T, "/")(rhs); }
    // ///ditto
    // VariantN opDiv_r(T)(T lhs)
    // {
    //     return VariantN(lhs).opArithmetic!(VariantN, "/")(this);
    // }
    ///ditto
    VariantN opMod(T)(T rhs) { return opArithmetic!(T, "%")(rhs); }
    // ///ditto
    // VariantN opMod_r(T)(T lhs)
    // {
    //     return VariantN(lhs).opArithmetic!(VariantN, "%")(this);
    // }
    ///ditto
    VariantN opAnd(T)(T rhs) { return opLogic!(T, "&")(rhs); }
    ///ditto
    VariantN opOr(T)(T rhs) { return opLogic!(T, "|")(rhs); }
    ///ditto
    VariantN opXor(T)(T rhs) { return opLogic!(T, "^")(rhs); }
    ///ditto
    VariantN opShl(T)(T rhs) { return opLogic!(T, "<<")(rhs); }
    // ///ditto
    // VariantN opShl_r(T)(T lhs)
    // {
    //     return VariantN(lhs).opLogic!(VariantN, "<<")(this);
    // }
    ///ditto
    VariantN opShr(T)(T rhs) { return opLogic!(T, ">>")(rhs); }
    // ///ditto
    // VariantN opShr_r(T)(T lhs)
    // {
    //     return VariantN(lhs).opLogic!(VariantN, ">>")(this);
    // }
    ///ditto
    VariantN opUShr(T)(T rhs) { return opLogic!(T, ">>>")(rhs); }
    // ///ditto
    // VariantN opUShr_r(T)(T lhs)
    // {
    //     return VariantN(lhs).opLogic!(VariantN, ">>>")(this);
    // }
    ///ditto
    VariantN opCat(T)(T rhs)
    {
        auto temp = this;
        temp ~= rhs;
        return temp;
    }
    // ///ditto
    // VariantN opCat_r(T)(T rhs)
    // {
    //     VariantN temp = rhs;
    //     temp ~= this;
    //     return temp;
    // }

    ///ditto
    VariantN opAddAssign(T)(T rhs)  { return this = this + rhs; }
    ///ditto
    VariantN opSubAssign(T)(T rhs)  { return this = this - rhs; }
    ///ditto
    VariantN opMulAssign(T)(T rhs)  { return this = this * rhs; }
    ///ditto
    VariantN opDivAssign(T)(T rhs)  { return this = this / rhs; }
    ///ditto
    VariantN opModAssign(T)(T rhs)  { return this = this % rhs; }
    ///ditto
    VariantN opAndAssign(T)(T rhs)  { return this = this & rhs; }
    ///ditto
    VariantN opOrAssign(T)(T rhs)   { return this = this | rhs; }
    ///ditto
    VariantN opXorAssign(T)(T rhs)  { return this = this ^ rhs; }
    ///ditto
    VariantN opShlAssign(T)(T rhs)  { return this = this << rhs; }
    ///ditto
    VariantN opShrAssign(T)(T rhs)  { return this = this >> rhs; }
    ///ditto
    VariantN opUShrAssign(T)(T rhs) { return this = this >>> rhs; }
    ///ditto
    VariantN opCatAssign(T)(T rhs)
    {
        auto toAppend = Variant(rhs);
        fptr(OpID.catAssign, &store, &toAppend) == 0 || assert(false);
        return this;
    }

    /**
     * Array and associative array operations. If a $(D
     * VariantN) contains an (associative) array, it can be indexed
     * into. Otherwise, an exception is thrown.
     */
    inout(Variant) opIndex(K)(K i) inout
    {
        auto result = Variant(i);
        fptr(OpID.index, cast(ubyte[size]*) &store, &result) == 0 || assert(false);
        return result;
    }

    ///
    unittest
    {
        Variant a = new int[10];
        a[5] = 42;
        assert(a[5] == 42);
        a[5] += 8;
        assert(a[5] == 50);

        int[int] hash = [ 42:24 ];
        a = hash;
        assert(a[42] == 24);
        a[42] /= 2;
        assert(a[42] == 12);
    }

    unittest
    {
        int[int] hash = [ 42:24 ];
        Variant v = hash;
        assert(v[42] == 24);
        v[42] = 5;
        assert(v[42] == 5);
    }

    /// ditto
    Variant opIndexAssign(T, N)(T value, N i)
    {
        Variant[2] args = [ Variant(value), Variant(i) ];
        fptr(OpID.indexAssign, &store, &args) == 0 || assert(false);
        return args[0];
    }

    /// ditto
    Variant opIndexOpAssign(string op, T, N)(T value, N i)
    {
        return opIndexAssign(mixin(`opIndex(i)` ~ op ~ `value`), i);
    }

    /** If the $(D VariantN) contains an (associative) array,
     * returns the length of that array. Otherwise, throws an
     * exception.
     */
    @property size_t length()
    {
        return cast(size_t) fptr(OpID.length, &store, null);
    }

    /**
       If the $(D VariantN) contains an array, applies $(D dg) to each
       element of the array in turn. Otherwise, throws an exception.
     */
    int opApply(Delegate)(scope Delegate dg) if (is(Delegate == delegate))
    {
        alias A = Parameters!(Delegate)[0];
        if (type == typeid(A[]))
        {
            auto arr = get!(A[]);
            foreach (ref e; arr)
            {
                if (dg(e)) return 1;
            }
        }
        else static if (is(A == VariantN))
        {
            foreach (i; 0 .. length)
            {
                // @@@TODO@@@: find a better way to not confuse
                // clients who think they change values stored in the
                // Variant when in fact they are only changing tmp.
                auto tmp = this[i];
                debug scope(exit) assert(tmp == this[i]);
                if (dg(tmp)) return 1;
            }
        }
        else
        {
            import std.conv : text;
            import std.exception : enforce;
            enforce(false, text("Variant type ", type,
                            " not iterable with values of type ",
                            A.stringof));
        }
        return 0;
    }
}

unittest
{
    import std.conv : to;
    Variant v;
    int foo() { return 42; }
    v = &foo;
    assert(v() == 42);

    static int bar(string s) { return to!int(s); }
    v = &bar;
    assert(v("43") == 43);
}

// opIndex with static arrays, issue 12771
unittest
{
    int[4] elements = [0, 1, 2, 3];
    Variant v = elements;
    assert(v == elements);
    assert(v[2] == 2);
    assert(v[3] == 3);
    v[2] = 6;
    assert(v[2] == 6);
    assert(v != elements);
}

//Issue# 8195
unittest
{
    struct S
    {
        int a;
        long b;
        string c;
        real d = 0.0;
        bool e;
    }

    static assert(S.sizeof >= Variant.sizeof);
    alias Types = AliasSeq!(string, int, S);
    alias MyVariant = VariantN!(maxSize!Types, Types);

    auto v = MyVariant(S.init);
    assert(v == S.init);
}

// Issue #10961
unittest
{
    // Primarily test that we can assign a void[] to a Variant.
    void[] elements = cast(void[])[1, 2, 3];
    Variant v = elements;
    void[] returned = v.get!(void[]);
    assert(returned == elements);
}

// Issue #13352
unittest
{
    alias TP = Algebraic!(long);
    auto a = TP(1L);
    auto b = TP(2L);
    assert(!TP.allowed!ulong);
    assert(a + b == 3L);
    assert(a + 2 == 3L);
    assert(1 + b == 3L);

    alias TP2 = Algebraic!(long, string);
    auto c = TP2(3L);
    assert(a + c == 4L);
}

// Issue #13354
unittest
{
    alias A = Algebraic!(string[]);
    A a = ["a", "b"];
    assert(a[0] == "a");
    assert(a[1] == "b");
    a[1] = "c";
    assert(a[1] == "c");

    alias AA = Algebraic!(int[string]);
    AA aa = ["a": 1, "b": 2];
    assert(aa["a"] == 1);
    assert(aa["b"] == 2);
    aa["b"] = 3;
    assert(aa["b"] == 3);
}

// Issue #14198
unittest
{
    Variant a = true;
    assert(a.type == typeid(bool));
}

// Issue #14233
unittest
{
    alias Atom = Algebraic!(string, This[]);

    Atom[] values = [];
    auto a = Atom(values);
}

pure nothrow @nogc
unittest
{
    Algebraic!(int, double) a;
    a = 100;
    a = 1.0;
}

// Issue 14457
unittest
{
    alias A = Algebraic!(int, float, double);
    alias B = Algebraic!(int, float);

    A a = 1;
    B b = 6f;
    a = b;

    assert(a.type == typeid(float));
    assert(a.get!float == 6f);
}

// Issue 14585
unittest
{
    static struct S
    {
        int x = 42;
        ~this() {assert(x == 42);}
    }
    Variant(S()).get!S;
}

// Issue 14586
unittest
{
    const Variant v = new immutable Object;
    v.get!(immutable Object);
}

unittest
{
    static struct S
    {
        T opCast(T)() {assert(false);}
    }
    Variant v = S();
    v.get!S;
}


/**
_Algebraic data type restricted to a closed set of possible
types. It's an alias for $(LREF VariantN) with an
appropriately-constructed maximum size. `Algebraic` is
useful when it is desirable to restrict what a discriminated type
could hold to the end of defining simpler and more efficient
manipulation.

*/
template Algebraic(T...)
{
    alias Algebraic = VariantN!(maxSize!T, T);
}

///
unittest
{
    auto v = Algebraic!(int, double, string)(5);
    assert(v.peek!(int));
    v = 3.14;
    assert(v.peek!(double));
    // auto x = v.peek!(long); // won't compile, type long not allowed
    // v = '1'; // won't compile, type char not allowed
}

/**
$(H4 Self-Referential Types)

A useful and popular use of algebraic data structures is for defining $(LUCKY
self-referential data structures), i.e. structures that embed references to
values of their own type within.

This is achieved with `Algebraic` by using `This` as a placeholder whenever a
reference to the type being defined is needed. The `Algebraic` instantiation
will perform $(LUCKY alpha renaming) on its constituent types, replacing `This`
with the self-referenced type. The structure of the type involving `This` may
be arbitrarily complex.
*/
unittest
{
    // A tree is either a leaf or a branch of two other trees
    alias Tree(Leaf) = Algebraic!(Leaf, Tuple!(This*, This*));
    Tree!int tree = tuple(new Tree!int(42), new Tree!int(43));
    Tree!int* right = tree.get!1[1];
    assert(*right == 43);

    // An object is a double, a string, or a hash of objects
    alias Obj = Algebraic!(double, string, This[string]);
    Obj obj = "hello";
    assert(obj.get!1 == "hello");
    obj = 42.0;
    assert(obj.get!0 == 42);
    obj = ["customer": Obj("John"), "paid": Obj(23.95)];
    assert(obj.get!2["customer"] == "John");
}

/**
Alias for $(LREF VariantN) instantiated with the largest size of `creal`,
`char[]`, and `void delegate()`. This ensures that `Variant` is large enough
to hold all of D's predefined types unboxed, including all numeric types,
pointers, delegates, and class references.  You may want to use
$(D VariantN) directly with a different maximum size either for
storing larger types unboxed, or for saving memory.
 */
alias Variant = VariantN!(maxSize!(creal, char[], void delegate()));

/**
 * Returns an array of variants constructed from $(D args).
 *
 * This is by design. During construction the $(D Variant) needs
 * static type information about the type being held, so as to store a
 * pointer to function for fast retrieval.
 */
Variant[] variantArray(T...)(T args)
{
    Variant[] result;
    foreach (arg; args)
    {
        result ~= Variant(arg);
    }
    return result;
}

///
unittest
{
    auto a = variantArray(1, 3.14, "Hi!");
    assert(a[1] == 3.14);
    auto b = Variant(a); // variant array as variant
    assert(b[1] == 3.14);
}

/**
 * Thrown in three cases:
 *
 * $(OL $(LI An uninitialized `Variant` is used in any way except
 * assignment and $(D hasValue);) $(LI A $(D get) or
 * $(D coerce) is attempted with an incompatible target type;)
 * $(LI A comparison between $(D Variant) objects of
 * incompatible types is attempted.))
 *
 */

// @@@ BUG IN COMPILER. THE 'STATIC' BELOW SHOULD NOT COMPILE
static class VariantException : Exception
{
    /// The source type in the conversion or comparison
    TypeInfo source;
    /// The target type in the conversion or comparison
    TypeInfo target;
    this(string s)
    {
        super(s);
    }
    this(TypeInfo source, TypeInfo target)
    {
        super("Variant: attempting to use incompatible types "
                            ~ source.toString()
                            ~ " and " ~ target.toString());
        this.source = source;
        this.target = target;
    }
}

unittest
{
    alias W1 = This2Variant!(char, int, This[int]);
    alias W2 = AliasSeq!(int, char[int]);
    static assert(is(W1 == W2));

    alias var_t = Algebraic!(void, string);
    var_t foo = "quux";
}

unittest
{
     alias A = Algebraic!(real, This[], This[int], This[This]);
     A v1, v2, v3;
     v2 = 5.0L;
     v3 = 42.0L;
     //v1 = [ v2 ][];
      auto v = v1.peek!(A[]);
     //writeln(v[0]);
     v1 = [ 9 : v3 ];
     //writeln(v1);
     v1 = [ v3 : v3 ];
     //writeln(v1);
}

unittest
{
    import std.conv : ConvException;
    import std.exception : assertThrown, collectException;
    // try it with an oddly small size
    VariantN!(1) test;
    assert(test.size > 1);

    // variantArray tests
    auto heterogeneous = variantArray(1, 4.5, "hi");
    assert(heterogeneous.length == 3);
    auto variantArrayAsVariant = Variant(heterogeneous);
    assert(variantArrayAsVariant[0] == 1);
    assert(variantArrayAsVariant.length == 3);

    // array tests
    auto arr = Variant([1.2].dup);
    auto e = arr[0];
    assert(e == 1.2);
    arr[0] = 2.0;
    assert(arr[0] == 2);
    arr ~= 4.5;
    assert(arr[1] == 4.5);

    // general tests
    Variant a;
    auto b = Variant(5);
    assert(!b.peek!(real) && b.peek!(int));
    // assign
    a = *b.peek!(int);
    // comparison
    assert(a == b, a.type.toString() ~ " " ~ b.type.toString());
    auto c = Variant("this is a string");
    assert(a != c);
    // comparison via implicit conversions
    a = 42; b = 42.0; assert(a == b);

    // try failing conversions
    bool failed = false;
    try
    {
        auto d = c.get!(int);
    }
    catch (Exception e)
    {
        //writeln(stderr, e.toString);
        failed = true;
    }
    assert(failed); // :o)

    // toString tests
    a = Variant(42); assert(a.toString() == "42");
    a = Variant(42.22); assert(a.toString() == "42.22");

    // coerce tests
    a = Variant(42.22); assert(a.coerce!(int) == 42);
    a = cast(short) 5; assert(a.coerce!(double) == 5);
    a = Variant("10"); assert(a.coerce!int == 10);

    a = Variant(1);
    assert(a.coerce!bool);
    a = Variant(0);
    assert(!a.coerce!bool);

    a = Variant(1.0);
    assert(a.coerce!bool);
    a = Variant(0.0);
    assert(!a.coerce!bool);
    a = Variant(float.init);
    assertThrown!ConvException(a.coerce!bool);

    a = Variant("true");
    assert(a.coerce!bool);
    a = Variant("false");
    assert(!a.coerce!bool);
    a = Variant("");
    assertThrown!ConvException(a.coerce!bool);

    // Object tests
    class B1 {}
    class B2 : B1 {}
    a = new B2;
    assert(a.coerce!(B1) !is null);
    a = new B1;
    assert(collectException(a.coerce!(B2) is null));
    a = cast(Object) new B2; // lose static type info; should still work
    assert(a.coerce!(B2) !is null);

//     struct Big { int a[45]; }
//     a = Big.init;

    // hash
    assert(a.toHash() != 0);
}

// tests adapted from
// http://www.dsource.org/projects/tango/browser/trunk/tango/core/Variant.d?rev=2601
unittest
{
    Variant v;

    assert(!v.hasValue);
    v = 42;
    assert( v.peek!(int) );
    assert( v.convertsTo!(long) );
    assert( v.get!(int) == 42 );
    assert( v.get!(long) == 42L );
    assert( v.get!(ulong) == 42uL );

    v = "Hello, World!";
    assert( v.peek!(string) );

    assert( v.get!(string) == "Hello, World!" );
    assert(!is(char[] : wchar[]));
    assert( !v.convertsTo!(wchar[]) );
    assert( v.get!(string) == "Hello, World!" );

    // Literal arrays are dynamically-typed
    v = cast(int[4]) [1,2,3,4];
    assert( v.peek!(int[4]) );
    assert( v.get!(int[4]) == [1,2,3,4] );

    {
         v = [1,2,3,4,5];
         assert( v.peek!(int[]) );
         assert( v.get!(int[]) == [1,2,3,4,5] );
    }

    v = 3.1413;
    assert( v.peek!(double) );
    assert( v.convertsTo!(real) );
    //@@@ BUG IN COMPILER: DOUBLE SHOULD NOT IMPLICITLY CONVERT TO FLOAT
    assert( !v.convertsTo!(float) );
    assert( *v.peek!(double) == 3.1413 );

    auto u = Variant(v);
    assert( u.peek!(double) );
    assert( *u.peek!(double) == 3.1413 );

    // operators
    v = 38;
    assert( v + 4 == 42 );
    assert( 4 + v == 42 );
    assert( v - 4 == 34 );
    assert( Variant(4) - v == -34 );
    assert( v * 2 == 76 );
    assert( 2 * v == 76 );
    assert( v / 2 == 19 );
    assert( Variant(2) / v == 0 );
    assert( v % 2 == 0 );
    assert( Variant(2) % v == 2 );
    assert( (v & 6) == 6 );
    assert( (6 & v) == 6 );
    assert( (v | 9) == 47 );
    assert( (9 | v) == 47 );
    assert( (v ^ 5) == 35 );
    assert( (5 ^ v) == 35 );
    assert( v << 1 == 76 );
    assert( Variant(1) << Variant(2) == 4 );
    assert( v >> 1 == 19 );
    assert( Variant(4) >> Variant(2) == 1 );
    assert( Variant("abc") ~ "def" == "abcdef" );
    assert( Variant("abc") ~ Variant("def") == "abcdef" );

    v = 38;
    v += 4;
    assert( v == 42 );
    v = 38; v -= 4; assert( v == 34 );
    v = 38; v *= 2; assert( v == 76 );
    v = 38; v /= 2; assert( v == 19 );
    v = 38; v %= 2; assert( v == 0 );
    v = 38; v &= 6; assert( v == 6 );
    v = 38; v |= 9; assert( v == 47 );
    v = 38; v ^= 5; assert( v == 35 );
    v = 38; v <<= 1; assert( v == 76 );
    v = 38; v >>= 1; assert( v == 19 );
    v = 38; v += 1;  assert( v < 40 );

    v = "abc";
    v ~= "def";
    assert( v == "abcdef", *v.peek!(char[]) );
    assert( Variant(0) < Variant(42) );
    assert( Variant(42) > Variant(0) );
    assert( Variant(42) > Variant(0.1) );
    assert( Variant(42.1) > Variant(1) );
    assert( Variant(21) == Variant(21) );
    assert( Variant(0) != Variant(42) );
    assert( Variant("bar") == Variant("bar") );
    assert( Variant("foo") != Variant("bar") );

    {
        auto v1 = Variant(42);
        auto v2 = Variant("foo");
        auto v3 = Variant(1+2.0i);

        int[Variant] hash;
        hash[v1] = 0;
        hash[v2] = 1;
        hash[v3] = 2;

        assert( hash[v1] == 0 );
        assert( hash[v2] == 1 );
        assert( hash[v3] == 2 );
    }

    {
        int[char[]] hash;
        hash["a"] = 1;
        hash["b"] = 2;
        hash["c"] = 3;
        Variant vhash = hash;

        assert( vhash.get!(int[char[]])["a"] == 1 );
        assert( vhash.get!(int[char[]])["b"] == 2 );
        assert( vhash.get!(int[char[]])["c"] == 3 );
    }
}

unittest
{
    // bug 1558
    Variant va=1;
    Variant vb=-2;
    assert((va+vb).get!(int) == -1);
    assert((va-vb).get!(int) == 3);
}

unittest
{
    Variant a;
    a=5;
    Variant b;
    b=a;
    Variant[] c;
    c = variantArray(1, 2, 3.0, "hello", 4);
    assert(c[3] == "hello");
}

unittest
{
    Variant v = 5;
    assert (!__traits(compiles, v.coerce!(bool delegate())));
}


unittest
{
    struct Huge {
        real a, b, c, d, e, f, g;
    }

    Huge huge;
    huge.e = 42;
    Variant v;
    v = huge;  // Compile time error.
    assert(v.get!(Huge).e == 42);
}

unittest
{
    const x = Variant(42);
    auto y1 = x.get!(const int);
    // @@@BUG@@@
    //auto y2 = x.get!(immutable int)();
}

// test iteration
unittest
{
    auto v = Variant([ 1, 2, 3, 4 ][]);
    auto j = 0;
    foreach (int i; v)
    {
        assert(i == ++j);
    }
    assert(j == 4);
}

// test convertibility
unittest
{
    auto v = Variant("abc".dup);
    assert(v.convertsTo!(char[]));
}

// http://d.puremagic.com/issues/show_bug.cgi?id=5424
unittest
{
    interface A {
        void func1();
    }
    static class AC: A {
        void func1() {
        }
    }

    A a = new AC();
    a.func1();
    Variant b = Variant(a);
}

unittest
{
    // bug 7070
    Variant v;
    v = null;
}

// Class and interface opEquals, issue 12157
unittest
{
    class Foo { }

    class DerivedFoo : Foo { }

    Foo f1 = new Foo();
    Foo f2 = new DerivedFoo();

    Variant v1 = f1, v2 = f2;
    assert(v1 == f1);
    assert(v1 != new Foo());
    assert(v1 != f2);
    assert(v2 != v1);
    assert(v2 == f2);
}

// Const parameters with opCall, issue 11361.
unittest
{
    static string t1(string c) {
        return c ~ "a";
    }

    static const(char)[] t2(const(char)[] p) {
        return p ~ "b";
    }

    static char[] t3(int p) {
        import std.conv : text;
        return p.text.dup;
    }

    Variant v1 = &t1;
    Variant v2 = &t2;
    Variant v3 = &t3;

    assert(v1("abc") == "abca");
    assert(v1("abc").type == typeid(string));
    assert(v2("abc") == "abcb");

    assert(v2(cast(char[])("abc".dup)) == "abcb");
    assert(v2("abc").type == typeid(const(char)[]));

    assert(v3(4) == ['4']);
    assert(v3(4).type == typeid(char[]));
}

// issue 12071
unittest
{
    static struct Structure { int data; }
    alias VariantTest = Algebraic!(Structure delegate() pure nothrow @nogc @safe);

    bool called = false;
    Structure example() pure nothrow @nogc @safe
    {
        called = true;
        return Structure.init;
    }
    auto m = VariantTest(&example);
    m();
    assert(called);
}

// Ordering comparisons of incompatible types, e.g. issue 7990.
unittest
{
    import std.exception : assertThrown;
    assertThrown!VariantException(Variant(3) < "a");
    assertThrown!VariantException("a" < Variant(3));
    assertThrown!VariantException(Variant(3) < Variant("a"));

    assertThrown!VariantException(Variant.init < Variant(3));
    assertThrown!VariantException(Variant(3) < Variant.init);
}

// Handling of unordered types, e.g. issue 9043.
unittest
{
    import std.exception : assertThrown;
    static struct A { int a; }

    assert(Variant(A(3)) != A(4));

    assertThrown!VariantException(Variant(A(3)) < A(4));
    assertThrown!VariantException(A(3) < Variant(A(4)));
    assertThrown!VariantException(Variant(A(3)) < Variant(A(4)));
}

// Handling of empty types and arrays, e.g. issue 10958
unittest
{
    class EmptyClass { }
    struct EmptyStruct { }
    alias EmptyArray = void[0];
    alias Alg = Algebraic!(EmptyClass, EmptyStruct, EmptyArray);

    Variant testEmpty(T)()
    {
        T inst;
        Variant v = inst;
        assert(v.get!T == inst);
        assert(v.peek!T !is null);
        assert(*v.peek!T == inst);
        Alg alg = inst;
        assert(alg.get!T == inst);
        return v;
    }

    testEmpty!EmptyClass();
    testEmpty!EmptyStruct();
    testEmpty!EmptyArray();

    // EmptyClass/EmptyStruct sizeof is 1, so we have this to test just size 0.
    EmptyArray arr = EmptyArray.init;
    Algebraic!(EmptyArray) a = arr;
    assert(a.length == 0);
    assert(a.get!EmptyArray == arr);
}

// Handling of void function pointers / delegates, e.g. issue 11360
unittest
{
    static void t1() { }
    Variant v = &t1;
    assert(v() == Variant.init);

    static int t2() { return 3; }
    Variant v2 = &t2;
    assert(v2() == 3);
}

// Using peek for large structs, issue 8580
unittest
{
    struct TestStruct(bool pad)
    {
        int val1;
        static if (pad)
            ubyte[Variant.size] padding;
        int val2;
    }

    void testPeekWith(T)()
    {
        T inst;
        inst.val1 = 3;
        inst.val2 = 4;
        Variant v = inst;
        T* original = v.peek!T;
        assert(original.val1 == 3);
        assert(original.val2 == 4);
        original.val1 = 6;
        original.val2 = 8;
        T modified = v.get!T;
        assert(modified.val1 == 6);
        assert(modified.val2 == 8);
    }

    testPeekWith!(TestStruct!false)();
    testPeekWith!(TestStruct!true)();
}

/**
 * Applies a delegate or function to the given $(LREF Algebraic) depending on the held type,
 * ensuring that all types are handled by the visiting functions.
 *
 * The delegate or function having the currently held value as parameter is called
 * with $(D variant)'s current value. Visiting handlers are passed
 * in the template parameter list.
 * It is statically ensured that all held types of
 * $(D variant) are handled across all handlers.
 * $(D visit) allows delegates and static functions to be passed
 * as parameters.
 *
 * If a function without parameters is specified, this function is called
 * when `variant` doesn't hold a value. Exactly one parameter-less function
 * is allowed.
 *
 * Duplicate overloads matching the same type in one of the visitors are disallowed.
 *
 * Returns: The return type of visit is deduced from the visiting functions and must be
 * the same across all overloads.
 * Throws: $(LREF VariantException) if `variant` doesn't hold a value and no
 * parameter-less fallback function is specified.
 */
template visit(Handlers...)
    if (Handlers.length > 0)
{
    ///
    auto visit(VariantType)(VariantType variant)
        if (isAlgebraic!VariantType)
    {
        return visitImpl!(true, VariantType, Handlers)(variant);
    }
}

///
unittest
{
    Algebraic!(int, string) variant;

    variant = 10;
    assert(variant.visit!((string s) => cast(int)s.length,
                          (int i)    => i)()
                          == 10);
    variant = "string";
    assert(variant.visit!((int i) => i,
                          (string s) => cast(int)s.length)()
                          == 6);

    // Error function usage
    Algebraic!(int, string) emptyVar;
    auto rslt = emptyVar.visit!((string s) => cast(int)s.length,
                          (int i)    => i,
                          () => -1)();
    assert(rslt == -1);
}

unittest
{
    Algebraic!(size_t, string) variant;

    // not all handled check
    static assert(!__traits(compiles, variant.visit!((size_t i){ })() ));

    variant = cast(size_t)10;
    auto which = 0;
    variant.visit!( (string s) => which = 1,
                    (size_t i) => which = 0
                    )();

    // integer overload was called
    assert(which == 0);

    // mustn't compile as generic Variant not supported
    Variant v;
    static assert(!__traits(compiles, v.visit!((string s) => which = 1,
                                               (size_t i) => which = 0
                                                )()
                                                ));

    static size_t func(string s) {
        return s.length;
    }

    variant = "test";
    assert( 4 == variant.visit!(func,
                                (size_t i) => i
                                )());

    Algebraic!(int, float, string) variant2 = 5.0f;
    // Shouldn' t compile as float not handled by visitor.
    static assert(!__traits(compiles, variant2.visit!(
                        (int) {},
                        (string) {})()));

    Algebraic!(size_t, string, float) variant3;
    variant3 = 10.0f;
    auto floatVisited = false;

    assert(variant3.visit!(
                 (float f) { floatVisited = true; return cast(size_t)f; },
                 func,
                 (size_t i) { return i; }
                 )() == 10);
    assert(floatVisited == true);

    Algebraic!(float, string) variant4;

    assert(variant4.visit!(func, (float f) => cast(size_t)f, () => size_t.max)() == size_t.max);

    // double error func check
    static assert(!__traits(compiles,
                            visit!(() => size_t.max, func, (float f) => cast(size_t)f, () => size_t.max)(variant4))
                 );
}

/**
 * Behaves as $(LREF visit) but doesn't enforce that all types are handled
 * by the visiting functions.
 *
 * If a parameter-less function is specified it is called when
 * either $(D variant) doesn't hold a value or holds a type
 * which isn't handled by the visiting functions.
 *
 * Returns: The return type of tryVisit is deduced from the visiting functions and must be
 * the same across all overloads.
 * Throws: $(LREF VariantException) if `variant` doesn't hold a value or
 * `variant` holds a value which isn't handled by the visiting functions,
 * when no parameter-less fallback function is specified.
 */
template tryVisit(Handlers...)
    if (Handlers.length > 0)
{
    ///
    auto tryVisit(VariantType)(VariantType variant)
        if (isAlgebraic!VariantType)
    {
        return visitImpl!(false, VariantType, Handlers)(variant);
    }
}

///
unittest
{
    Algebraic!(int, string) variant;

    variant = 10;
    auto which = -1;
    variant.tryVisit!((int i) { which = 0; })();
    assert(which == 0);

    // Error function usage
    variant = "test";
    variant.tryVisit!((int i) { which = 0; },
                      ()      { which = -100; })();
    assert(which == -100);
}

unittest
{
    import std.exception : assertThrown;
    Algebraic!(int, string) variant;

    variant = 10;
    auto which = -1;
    variant.tryVisit!((int i){ which = 0; })();

    assert(which == 0);

    variant = "test";

    assertThrown!VariantException(variant.tryVisit!((int i) { which = 0; })());

    void errorfunc()
    {
        which = -1;
    }

    variant.tryVisit!((int i) { which = 0; }, errorfunc)();

    assert(which == -1);
}

private template isAlgebraic(Type)
{
    static if (is(Type _ == VariantN!T, T...))
        enum isAlgebraic = T.length >= 2; // T[0] == maxDataSize, T[1..$] == AllowedTypesParam
    else
        enum isAlgebraic = false;
}

unittest
{
    static assert(!isAlgebraic!(Variant));
    static assert( isAlgebraic!(Algebraic!(string)));
    static assert( isAlgebraic!(Algebraic!(int, int[])));
}

private auto visitImpl(bool Strict, VariantType, Handler...)(VariantType variant)
    if (isAlgebraic!VariantType && Handler.length > 0)
{
    alias AllowedTypes = VariantType.AllowedTypes;


    /**
     * Returns: Struct where $(D indices)  is an array which
     * contains at the n-th position the index in Handler which takes the
     * n-th type of AllowedTypes. If an Handler doesn't match an
     * AllowedType, -1 is set. If a function in the delegates doesn't
     * have parameters, the field $(D exceptionFuncIdx) is set;
     * otherwise it's -1.
     */
    auto visitGetOverloadMap()
    {
        struct Result {
            int[AllowedTypes.length] indices;
            int exceptionFuncIdx = -1;
        }

        Result result;

        foreach (tidx, T; AllowedTypes)
        {
            bool added = false;
            foreach (dgidx, dg; Handler)
            {
                // Handle normal function objects
                static if (isSomeFunction!dg)
                {
                    alias Params = Parameters!dg;
                    static if (Params.length == 0)
                    {
                        // Just check exception functions in the first
                        // inner iteration (over delegates)
                        if (tidx > 0)
                            continue;
                        else
                        {
                            if (result.exceptionFuncIdx != -1)
                                assert(false, "duplicate parameter-less (error-)function specified");
                            result.exceptionFuncIdx = dgidx;
                        }
                    }
                    else static if (is(Params[0] == T) || is(Unqual!(Params[0]) == T))
                    {
                        if (added)
                            assert(false, "duplicate overload specified for type '" ~ T.stringof ~ "'");

                        added = true;
                        result.indices[tidx] = dgidx;
                    }
                }
                // Handle composite visitors with opCall overloads
                else
                {
                    static assert(false, dg.stringof ~ " is not a function or delegate");
                }
            }

            if (!added)
                result.indices[tidx] = -1;
        }

        return result;
    }

    enum HandlerOverloadMap = visitGetOverloadMap();

    if (!variant.hasValue)
    {
        // Call the exception function. The HandlerOverloadMap
        // will have its exceptionFuncIdx field set to value != -1 if an
        // exception function has been specified; otherwise we just through an exception.
        static if (HandlerOverloadMap.exceptionFuncIdx != -1)
            return Handler[ HandlerOverloadMap.exceptionFuncIdx ]();
        else
            throw new VariantException("variant must hold a value before being visited.");
    }

    foreach (idx, T; AllowedTypes)
    {
        if (auto ptr = variant.peek!T)
        {
            enum dgIdx = HandlerOverloadMap.indices[idx];

            static if (dgIdx == -1)
            {
                static if (Strict)
                    static assert(false, "overload for type '" ~ T.stringof ~ "' hasn't been specified");
                else
                {
                    static if (HandlerOverloadMap.exceptionFuncIdx != -1)
                        return Handler[ HandlerOverloadMap.exceptionFuncIdx ]();
                    else
                        throw new VariantException(
                            "variant holds value of type '"
                            ~ T.stringof ~
                            "' but no visitor has been provided"
                        );
                }
            }
            else
            {
                return Handler[ dgIdx ](*ptr);
            }
        }
    }

    assert(false);
}

unittest
{
    // validate that visit can be called with a const type
    struct Foo { int depth; }
    struct Bar { int depth; }
    alias FooBar = Algebraic!(Foo, Bar);

    int depth(in FooBar fb) {
        return fb.visit!((Foo foo) => foo.depth,
                         (Bar bar) => bar.depth);
    }

    FooBar fb = Foo(3);
    assert(depth(fb) == 3);
}

unittest
{
    // https://issues.dlang.org/show_bug.cgi?id=16383
    class Foo {this() immutable {}}
    alias V = Algebraic!(immutable Foo);

    auto x = V(new immutable Foo).visit!(
        (immutable(Foo) _) => 3
    );
    assert(x == 3);
}

unittest
{
    // http://d.puremagic.com/issues/show_bug.cgi?id=5310
    const Variant a;
    assert(a == a);
    Variant b;
    assert(a == b);
    assert(b == a);
}

unittest
{
    const Variant a = [2];
    assert(a[0] == 2);
}

unittest
{
    // http://d.puremagic.com/issues/show_bug.cgi?id=10017
    static struct S
    {
        ubyte[Variant.size + 1] s;
    }

    Variant v1, v2;
    v1 = S(); // the payload is allocated on the heap
    v2 = v1;  // AssertError: target must be non-null
    assert(v1 == v2);
}
unittest
{
    import std.exception : assertThrown;
    // http://d.puremagic.com/issues/show_bug.cgi?id=7069
    Variant v;

    int i = 10;
    v = i;
    foreach (qual; AliasSeq!(MutableOf, ConstOf))
    {
        assert(v.get!(qual!int) == 10);
        assert(v.get!(qual!float) == 10.0f);
    }
    foreach (qual; AliasSeq!(ImmutableOf, SharedOf, SharedConstOf))
    {
        assertThrown!VariantException(v.get!(qual!int));
    }

    const(int) ci = 20;
    v = ci;
    foreach (qual; AliasSeq!(ConstOf))
    {
        assert(v.get!(qual!int) == 20);
        assert(v.get!(qual!float) == 20.0f);
    }
    foreach (qual; AliasSeq!(MutableOf, ImmutableOf, SharedOf, SharedConstOf))
    {
        assertThrown!VariantException(v.get!(qual!int));
        assertThrown!VariantException(v.get!(qual!float));
    }

    immutable(int) ii = ci;
    v = ii;
    foreach (qual; AliasSeq!(ImmutableOf, ConstOf, SharedConstOf))
    {
        assert(v.get!(qual!int) == 20);
        assert(v.get!(qual!float) == 20.0f);
    }
    foreach (qual; AliasSeq!(MutableOf, SharedOf))
    {
        assertThrown!VariantException(v.get!(qual!int));
        assertThrown!VariantException(v.get!(qual!float));
    }

    int[] ai = [1,2,3];
    v = ai;
    foreach (qual; AliasSeq!(MutableOf, ConstOf))
    {
        assert(v.get!(qual!(int[])) == [1,2,3]);
        assert(v.get!(qual!(int)[]) == [1,2,3]);
    }
    foreach (qual; AliasSeq!(ImmutableOf, SharedOf, SharedConstOf))
    {
        assertThrown!VariantException(v.get!(qual!(int[])));
        assertThrown!VariantException(v.get!(qual!(int)[]));
    }

    const(int[]) cai = [4,5,6];
    v = cai;
    foreach (qual; AliasSeq!(ConstOf))
    {
        assert(v.get!(qual!(int[])) == [4,5,6]);
        assert(v.get!(qual!(int)[]) == [4,5,6]);
    }
    foreach (qual; AliasSeq!(MutableOf, ImmutableOf, SharedOf, SharedConstOf))
    {
        assertThrown!VariantException(v.get!(qual!(int[])));
        assertThrown!VariantException(v.get!(qual!(int)[]));
    }

    immutable(int[]) iai = [7,8,9];
    v = iai;
    //assert(v.get!(immutable(int[])) == [7,8,9]);   // Bug ??? runtime error
    assert(v.get!(immutable(int)[]) == [7,8,9]);
    assert(v.get!(const(int[])) == [7,8,9]);
    assert(v.get!(const(int)[]) == [7,8,9]);
    //assert(v.get!(shared(const(int[]))) == cast(shared const)[7,8,9]);    // Bug ??? runtime error
    //assert(v.get!(shared(const(int))[]) == cast(shared const)[7,8,9]);    // Bug ??? runtime error
    foreach (qual; AliasSeq!(MutableOf))
    {
        assertThrown!VariantException(v.get!(qual!(int[])));
        assertThrown!VariantException(v.get!(qual!(int)[]));
    }

    class A {}
    class B : A {}
    B b = new B();
    v = b;
    foreach (qual; AliasSeq!(MutableOf, ConstOf))
    {
        assert(v.get!(qual!B) is b);
        assert(v.get!(qual!A) is b);
        assert(v.get!(qual!Object) is b);
    }
    foreach (qual; AliasSeq!(ImmutableOf, SharedOf, SharedConstOf))
    {
        assertThrown!VariantException(v.get!(qual!B));
        assertThrown!VariantException(v.get!(qual!A));
        assertThrown!VariantException(v.get!(qual!Object));
    }

    const(B) cb = new B();
    v = cb;
    foreach (qual; AliasSeq!(ConstOf))
    {
        assert(v.get!(qual!B) is cb);
        assert(v.get!(qual!A) is cb);
        assert(v.get!(qual!Object) is cb);
    }
    foreach (qual; AliasSeq!(MutableOf, ImmutableOf, SharedOf, SharedConstOf))
    {
        assertThrown!VariantException(v.get!(qual!B));
        assertThrown!VariantException(v.get!(qual!A));
        assertThrown!VariantException(v.get!(qual!Object));
    }

    immutable(B) ib = new immutable(B)();
    v = ib;
    foreach (qual; AliasSeq!(ImmutableOf, ConstOf, SharedConstOf))
    {
        assert(v.get!(qual!B) is ib);
        assert(v.get!(qual!A) is ib);
        assert(v.get!(qual!Object) is ib);
    }
    foreach (qual; AliasSeq!(MutableOf, SharedOf))
    {
        assertThrown!VariantException(v.get!(qual!B));
        assertThrown!VariantException(v.get!(qual!A));
        assertThrown!VariantException(v.get!(qual!Object));
    }

    shared(B) sb = new shared B();
    v = sb;
    foreach (qual; AliasSeq!(SharedOf, SharedConstOf))
    {
        assert(v.get!(qual!B) is sb);
        assert(v.get!(qual!A) is sb);
        assert(v.get!(qual!Object) is sb);
    }
    foreach (qual; AliasSeq!(MutableOf, ImmutableOf, ConstOf))
    {
        assertThrown!VariantException(v.get!(qual!B));
        assertThrown!VariantException(v.get!(qual!A));
        assertThrown!VariantException(v.get!(qual!Object));
    }

    shared(const(B)) scb = new shared const B();
    v = scb;
    foreach (qual; AliasSeq!(SharedConstOf))
    {
        assert(v.get!(qual!B) is scb);
        assert(v.get!(qual!A) is scb);
        assert(v.get!(qual!Object) is scb);
    }
    foreach (qual; AliasSeq!(MutableOf, ConstOf, ImmutableOf, SharedOf))
    {
        assertThrown!VariantException(v.get!(qual!B));
        assertThrown!VariantException(v.get!(qual!A));
        assertThrown!VariantException(v.get!(qual!Object));
    }
}

unittest
{
    static struct DummyScope
    {
        // https://d.puremagic.com/issues/show_bug.cgi?id=12540
        alias Alias12540 = Algebraic!Class12540;

        static class Class12540
        {
            Alias12540 entity;
        }
    }
}

unittest
{
    // https://issues.dlang.org/show_bug.cgi?id=10194
    // Also test for elaborate copying
    static struct S
    {
        @disable this();
        this(int dummy)
        {
            ++cnt;
        }

        this(this)
        {
            ++cnt;
        }

        @disable S opAssign();

        ~this()
        {
            --cnt;
            assert(cnt >= 0);
        }
        static int cnt = 0;
    }

    {
        Variant v;
        {
            v = S(0);
            assert(S.cnt == 1);
        }
        assert(S.cnt == 1);

        // assigning a new value should destroy the existing one
        v = 0;
        assert(S.cnt == 0);

        // destroying the variant should destroy it's current value
        v = S(0);
        assert(S.cnt == 1);
    }
    assert(S.cnt == 0);
}

unittest
{
    // Bugzilla 13300
    static struct S
    {
        this(this) {}
        ~this() {}
    }

    static assert( hasElaborateCopyConstructor!(Variant));
    static assert(!hasElaborateCopyConstructor!(Algebraic!bool));
    static assert( hasElaborateCopyConstructor!(Algebraic!S));
    static assert( hasElaborateCopyConstructor!(Algebraic!(bool, S)));

    static assert( hasElaborateDestructor!(Variant));
    static assert(!hasElaborateDestructor!(Algebraic!bool));
    static assert( hasElaborateDestructor!(Algebraic!S));
    static assert( hasElaborateDestructor!(Algebraic!(bool, S)));

    import std.array;
    alias Value = Algebraic!bool;

    static struct T
    {
        Value value;
        @disable this();
    }
    auto a = appender!(T[]);
}

unittest
{
    // Bugzilla 13871
    alias A = Algebraic!(int, typeof(null));
    static struct B { A value; }
    alias C = std.variant.Algebraic!B;

    C var;
    var = C(B());
}

unittest
{
    import std.exception : assertThrown, assertNotThrown;
    // Make sure Variant can handle types with opDispatch but no length field.
    struct SWithNoLength
    {
        void opDispatch(string s)() { }
    }

    struct SWithLength
    {
        @property int opDispatch(string s)()
        {
            // Assume that s == "length"
            return 5; // Any value is OK for test.
        }
    }

    SWithNoLength sWithNoLength;
    Variant v = sWithNoLength;
    assertThrown!VariantException(v.length);

    SWithLength sWithLength;
    v = sWithLength;
    assertNotThrown!VariantException(v.get!SWithLength.length);
    assertThrown!VariantException(v.length);
}

unittest
{
    // Bugzilla 13534
    static assert(!__traits(compiles, () @safe {
        auto foo() @system { return 3; }
        auto v = Variant(&foo);
        v(); // foo is called in safe code!?
    }));
}

unittest
{
    // Bugzilla 15039
    import std.variant;
    import std.typecons;

    alias IntTypedef = Typedef!int;
    alias Obj = Algebraic!(int, IntTypedef, This[]);

    Obj obj = 1;

    obj.visit!(
        (int x) {},
        (IntTypedef x) {},
        (Obj[] x) {},
    );
}

unittest
{
    // Bugzilla 15791
    int n = 3;
    struct NS1 { int foo() { return n + 10; } }
    struct NS2 { int foo() { return n * 10; } }

    Variant v;
    v = NS1();
    assert(v.get!NS1.foo() == 13);
    v = NS2();
    assert(v.get!NS2.foo() == 30);
}

unittest
{
    // Bugzilla 15827
    static struct Foo15827 { Variant v; this(Foo15827 v) {} }
    Variant v = Foo15827.init;
}
