// Written in the D programming language
/++
This module defines functions to parse units and quantities. The text
input is parsed according to the following grammar. For example:
$(DL
$(DT Prefixes and unit symbols must be joined:)
    $(DD "1 mm" = 1 millimeter)
    $(DD "1 m m" = 1 square meter)
$(BR)
$(DT Standalone units are preferred over prefixed ones:)
    $(DD "1 cd" = 1 candela, not 1 centiday)
$(BR)
$(DT Powers of units:)
    $(DD "1 m^2")
    $(DD "1 m²" $(I (superscript integer)))
$(BR)
$(DT Multiplication of to units:)
    $(DD "1 N m" $(I (whitespace)))
    $(DD "1 N . m")
    $(DD "1 N ⋅ m" $(I (centered dot)))
    $(DD "1 N * m")
    $(DD "1 N × m" $(I (times sign)))
$(BR)
$(DT Division of to units:)
    $(DD "1 mol / s")
    $(DD "1 mol ÷ s")
$(BR)
$(DT Grouping of units with parentheses:)
    $(DD "1 kg/(m.s^2)" = 1 kg m⁻¹ s⁻²)
)

Grammar: (whitespace not significant)
$(DL
$(DT Quantity:)
    $(DD Units)
    $(DD Number Units)
$(BR)
$(DT Number:)
    $(DD $(I Numeric value parsed by std.conv.parse!real))
$(BR)
$(DT Units:)
    $(DD Unit)
    $(DD Unit Units)
    $(DD Unit Operator Units)
$(BR)
$(DT Operator:)
    $(DD $(B *))
    $(DD $(B .))
    $(DD $(B ⋅))
    $(DD $(B ×))
    $(DD $(B /))
    $(DD $(B ÷))
$(BR)
$(DT Unit:)
    $(DD Base)
    $(DD Base $(B ^) Integer)
    $(DD Base SupInteger)
$(BR)
$(DT Base:)
    $(DD Symbol)
    $(DD Prefix Symbol)
    $(DD $(B $(LPAREN)) Units $(B $(RPAREN)))
$(BR)
$(DT Symbol:)
    $(DD $(I The symbol of a valid unit))
$(BR)
$(DT Prefix:)
    $(DD $(I The symbol of a valid prefix))
$(BR)
$(DT Integer:)
    $(DD $(I Integer value parsed by std.conv.parse!int))
$(BR)
$(DT SupInteger:)
    $(DD $(I Superscript version of Integer))
)

Copyright: Copyright 2013, Nicolas Sicard
Authors: Nicolas Sicard
License: $(LINK www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
Source: $(LINK https://github.com/biozic/quantities)
+/
module quantities.parsing;

import quantities.base;
import quantities.si;

import std.array;
import std.algorithm;
import std.conv;
import std.exception;
import std.math;
import std.range;
import std.string;
import std.traits;
import std.utf;

version (unittest)
{
    import std.math : approxEqual;

    private QuantityParser defaultParser()
    {
        return QuantityParser(SymbolList.siList);
    }
}

private struct AddUnit(Q)
{
    string symbol;
    Q unit;
}

auto addUnit(Q)(string symbol, Q unit)
    if (isQuantity!Q)
{
    return AddUnit!Q(symbol, unit);
}

private struct AddPrefix
{
    string symbol;
    real factor;
}

auto addPrefix(string symbol, real factor)
{
    return AddPrefix(symbol, factor);
}

/++
Creates a compile-time parser capable of working on user-defined units
and prefixes.

By default, the parser knows about SI units and prefixes. The user can add
more units and prefix in the template parameters, using the global addUnit and addPrefix
functions templates.
+/
template ctQuantityParser(Sym...)
{
    enum symbolList = {
        SymbolList ret;
        foreach (symbol, unit; siRTUnits)
            ret.units[symbol] = unit;
        foreach (symbol, prefix; siRTPrefixes)
            ret.prefixes[symbol] = prefix;
        ret.maxPrefixLength = 2;

        foreach (sym; Sym)
        {
            static if (is(typeof(sym) _ : AddUnit!Q, Q))
            {
                ret.units[sym.symbol] = sym.unit.toRuntime;
            }
            else static if (is(typeof(sym) == AddPrefix))
            {
                ret.prefixes[sym.symbol] = sym.factor;
                if (sym.symbol.length > ret.maxPrefixLength)
                    ret.maxPrefixLength = sym.symbol.length;
            }
            else
                static assert(false, "Unexpected symbol: " ~ sym.stringof);
        }

        return ret;
    }();

    template ctQuantityParser(string str, N = real)
    {
        private string dimTup(int[string] dims)
        {
            return dims.keys.map!(x => `"%s", %s`.format(x, dims[x])).join(", ");
        }
        
        // This is for a nice compile-time error message
        enum msg = { return collectExceptionMsg(parseRTQuantity(str, symbolList)); }();
        static if (msg)
        {
            static assert(false, msg);
        }
        else
        {
            enum q = parseRTQuantity(str, symbolList);
            enum dimStr = dimTup(q.dimensions);
            mixin("alias dims = TypeTuple!(%s);".format(dimStr));
            enum ctQuantityParser = Quantity!(N, Sort!dims).make(q.value);
        }
    }
}
///
unittest
{
    enum bit = unit!"bit";
    enum byte_ = 8 * bit;

    alias sz = ctQuantityParser!(
        addUnit("bit", bit),
        addUnit("B", byte_),
        addPrefix("hob", 7)
    );

    enum size = sz!"1 MiB";
    assert(size.toString!("%.0f bit", sz) == "8388608 bit");

    enum height = sz!"1 hobbit";
    assert(height.value(sz!"bit") == 7);
}

/++
Parses a string for a a SI-compatible quantity.
+/
alias si = ctQuantityParser!();
///
unittest
{
    enum min = si!"min";
    enum inch = si!"2.54 cm";

    auto conc = si!"1 µmol/L";
    auto speed = si!"m s^-1";
    auto value = si!"0.5";

    static assert(is(typeof(conc) == Concentration));
    static assert(is(typeof(speed) == Speed));
    static assert(is(typeof(value) == Dimensionless));
}

/// Parses text for a unit or a quantity at runtime.
auto parseQuantity(Q, S)(S text, SymbolList symbolList = SymbolList.siList)
    if (isQuantity!Q)
{
    return Q(parseRTQuantity(text, symbolList));
}
///
unittest
{
    alias Time = QuantityType!second;
    alias Length = QuantityType!meter;
    // Note: these are also predefined in quantities.si

    // Parse times
    auto t = parseQuantity!Time("90 min");
    assert(t == 90 * minute);
    t = parseQuantity!Time("h");
    assert(t == 1 * hour);

    // Add a user-defined symbol (here a unit) to the default list
    auto symbols = SymbolList.siList;
    symbols.addUnit("in", si!"2.54 cm");
    auto len = parseQuantity!Length("17 in", symbols);
    assert(len.value(centi(meter)).approxEqual(17 * 2.54));
}

RTQuantity parseRTQuantity(S)(S text, SymbolList symbolList = SymbolList.siList)
{
    static assert(isForwardRange!S && isSomeChar!(ElementType!S),
                  "text must be a forward range of a character type");

    real value; // nan
    try
    {
        // This throws if there is no value ("no digits seen")
        value = std.conv.parse!real(text);
    }
    catch
    {
        value = 1;
    }

    if (text.empty)
        return RTQuantity(value, null);

    auto input = text.to!string;
    auto tokens = lex(input);
    auto parser = QuantityParser(symbolList);

    RTQuantity result = parser.parseCompoundUnit(tokens);
    result.value *= value;
    return result;
}

unittest // Parsing a range of characters that is not a string
{
    Concentration c = parseRTQuantity(
        ["11.2", "<- value", "µmol/L", "<-unit"]
        .filter!(x => !x.startsWith("<"))
        .joiner(" ")
    );
    assert(c.value(nano(mole)/liter).approxEqual(11200));
}

unittest // Examples from the header
{
    auto J = toRuntime(joule);
    assert(parseRTQuantity("1 N m") == J);
    assert(parseRTQuantity("1 N.m") == J);
    assert(parseRTQuantity("1 N⋅m") == J);
    assert(parseRTQuantity("1 N * m") == J);
    assert(parseRTQuantity("1 N × m") == J);

    auto kat = toRuntime(katal);
    assert(parseRTQuantity("1 mol s^-1") == kat);
    assert(parseRTQuantity("1 mol s⁻¹") == kat);
    assert(parseRTQuantity("1 mol/s") == kat);

    auto Pa = toRuntime(pascal);
    assert(parseRTQuantity("1 kg m^-1 s^-2") == Pa);
    assert(parseRTQuantity("1 kg/(m s^2)") == Pa);
}

unittest // Test parsing
{
    import std.math : approxEqual;

    assertThrown!ParsingException(parseRTQuantity("1 µ m"));
    assertThrown!ParsingException(parseRTQuantity("1 µ"));
    assertThrown!ParsingException(parseRTQuantity("1 g/"));
    assertThrown!ParsingException(parseRTQuantity("1 g^"));

    string test = "1    m    ";
    assert(parseRTQuantity(test) == meter.toRuntime);
    assert(parseRTQuantity("1 µm").value.approxEqual(micro(meter).rawValue));

    assert(parseRTQuantity("1 m^-1") == toRuntime(1 / meter));
    assert(parseRTQuantity("1 m²") == square(meter).toRuntime);
    assert(parseRTQuantity("1 m⁻¹") == toRuntime(1 / meter));
    assert(parseRTQuantity("1 (m)") == meter.toRuntime);
    assert(parseRTQuantity("1 (m^-1)") == toRuntime(1 / meter));
    assert(parseRTQuantity("1 ((m)^-1)^-1") == meter.toRuntime);

    assert(parseRTQuantity("1 m * m") == square(meter).toRuntime);
    assert(parseRTQuantity("1 m m") == square(meter).toRuntime);
    assert(parseRTQuantity("1 m . m") == square(meter).toRuntime);
    assert(parseRTQuantity("1 m ⋅ m") == square(meter).toRuntime);
    assert(parseRTQuantity("1 m × m") == square(meter).toRuntime);
    assert(parseRTQuantity("1 m / m") == toRuntime(meter / meter));
    assert(parseRTQuantity("1 m ÷ m") == toRuntime(meter / meter));

    assert(parseRTQuantity("1 N.m") == toRuntime(newton * meter));
    assert(parseRTQuantity("1 N m") == toRuntime(newton * meter));

    assert(parseRTQuantity("6.3 L.mmol^-1.cm^-1").value.approxEqual(630));
    assert(parseRTQuantity("6.3 L/(mmol*cm)").value.approxEqual(630));
    assert(parseRTQuantity("6.3 L*(mmol*cm)^-1").value.approxEqual(630));
    assert(parseRTQuantity("6.3 L/mmol/cm").value.approxEqual(630));
}

// Holds a value and a dimensions for parsing
struct RTQuantity
{
    // The payload
    real value;

    // The dimensions of the quantity
    int[string] dimensions;
}

// A parser that can parse a text for a unit or a quantity
struct QuantityParser
{
    private SymbolList symbolList;

    RTQuantity parseCompoundUnit(T)(auto ref T[] tokens, bool inParens = false)
        if (is(T : Token))
    {
        RTQuantity ret = parseExponentUnit(tokens);
        if (tokens.empty || (inParens && tokens.front.type == Tok.rparen))
            return ret;

        do {
            tokens.check();
            auto cur = tokens.front;

            bool multiply = true;
            if (cur.type == Tok.div)
                multiply = false;

            if (cur.type == Tok.mul || cur.type == Tok.div)
            {
                tokens.advance();
                tokens.check();
                cur = tokens.front;
            }

            RTQuantity rhs = parseExponentUnit(tokens);
            if (multiply)
            {
                ret.dimensions = ret.dimensions.binop!"*"(rhs.dimensions);
                ret.value = ret.value * rhs.value;
            }
            else
            {
                ret.dimensions = ret.dimensions.binop!"/"(rhs.dimensions);
                ret.value = ret.value / rhs.value;
            }

            if (tokens.empty || (inParens && tokens.front.type == Tok.rparen))
                break;

            cur = tokens.front;
        }
        while (!tokens.empty);

        return ret;
    }
    unittest
    {
        assert(defaultParser.parseCompoundUnit(lex("m * m")) == square(meter).toRuntime);
        assert(defaultParser.parseCompoundUnit(lex("m m")) == square(meter).toRuntime);
        assert(defaultParser.parseCompoundUnit(lex("m * m / m")) == meter.toRuntime);
        assertThrown!ParsingException(defaultParser.parseCompoundUnit(lex("m ) m")));
        assertThrown!ParsingException(defaultParser.parseCompoundUnit(lex("m * m) m")));
    }

    RTQuantity parseExponentUnit(T)(auto ref T[] tokens)
        if (is(T : Token))
    {
        RTQuantity ret = parseUnit(tokens);

        if (tokens.empty)
            return ret;

        auto next = tokens.front;
        if (next.type != Tok.exp && next.type != Tok.supinteger)
            return ret;

        if (next.type == Tok.exp)
            tokens.advance(Tok.integer);

        int n = parseInteger(tokens);

        return RTQuantity(std.math.pow(ret.value, n), ret.dimensions.exp(n));
    }
    unittest
    {
        assert(defaultParser.parseExponentUnit(lex("m²")) == square(meter).toRuntime);
        assert(defaultParser.parseExponentUnit(lex("m^2")) == square(meter).toRuntime);
        assertThrown!ParsingException(defaultParser.parseExponentUnit(lex("m^²")));
    }

    int parseInteger(T)(auto ref T[] tokens)
        if (is(T : Token))
    {
        tokens.check(Tok.integer, Tok.supinteger);
        int n = tokens.front.integer;
        if (tokens.length)
            tokens.advance();
        return n;
    }
    unittest
    {
        assert(defaultParser.parseInteger(lex("-123")) == -123);
        assert(defaultParser.parseInteger(lex("⁻¹²³")) == -123);
        assertThrown!ParsingException(defaultParser.parseInteger(lex("1-⁺⁵")));
    }

    RTQuantity parseUnit(T)(auto ref T[] tokens)
        if (is(T : Token))
    {
        RTQuantity ret;

        if (tokens.front.type == Tok.lparen)
        {
            tokens.advance();
            ret = parseCompoundUnit(tokens, true);
            tokens.check(Tok.rparen);
            tokens.advance();
        }
        else
            ret = parsePrefixUnit(tokens);

        return ret;
    }
    unittest
    {
        assert(defaultParser.parseUnit(lex("(m)")) == meter.toRuntime);
        assertThrown!ParsingException(defaultParser.parseUnit(lex("(m")));
    }

    RTQuantity parsePrefixUnit(T)(auto ref T[] tokens)
        if (is(T : Token))
    {
        tokens.check(Tok.symbol);
        auto str = tokens.front.slice;
        if (tokens.length)
            tokens.advance();

        // Try a standalone unit symbol (no prefix)
        auto uptr = str in symbolList.units;
        if (uptr)
            return *uptr;

        // Try with prefixes, the longest prefix first
        real* factor;
        for (size_t i = symbolList.maxPrefixLength; i > 0; i--)
        {
            if (str.length >= i)
            {
                string prefix = str[0 .. i].to!string;
                factor = prefix in symbolList.prefixes;
                if (factor)
                {
                    string unit = str[i .. $].to!string;
                    enforceEx!ParsingException(unit.length, "Expecting a unit after the prefix " ~ prefix);
                    uptr = unit in symbolList.units;
                    if (uptr)
                        return RTQuantity(*factor * uptr.value, uptr.dimensions);
                }
            }
        }

        throw new ParsingException("Unknown unit symbol: '%s'".format(str));
    }
    unittest
    {
        assert(defaultParser.parsePrefixUnit(lex("mm")).value.approxEqual(milli(meter).rawValue));
        assert(defaultParser.parsePrefixUnit(lex("cd")).value.approxEqual(candela.rawValue));
        assertThrown!ParsingException(defaultParser.parsePrefixUnit(lex("Lm")));
    }
}

/**
This struct contains the symbols of the units and the prefixes that the
parser can handle.
*/
struct SymbolList
{
    private
    {
        RTQuantity[string] units;
        real[string] prefixes;
        size_t maxPrefixLength;

        static SymbolList _defaultList;
        static this()
        {
            _defaultList = SymbolList(siRTUnits, siRTPrefixes, 2);
        }
    }

    /// Returns the default list, consisting of the main SI units and prefixes.
    static SymbolList siList()
    {
        if (__ctfe)
            return SymbolList(siRTUnits, siRTPrefixes, 2);
        return _defaultList;
    }

    /// Adds a new prefix to the list
    void addPrefix(string symbol, real factor)
    {
        // COW
        if (prefixes is _defaultList.prefixes)
            prefixes = _defaultList.prefixes.dup;

        prefixes[symbol] = factor;
        if (symbol.length > maxPrefixLength)
            maxPrefixLength = symbol.length;
    }

    /// Adds a new unit to the list
    void addUnit(Q)(string symbol, Q unit)
        if (isQuantity!Q)
    {
        // COW
        if (units is _defaultList.units)
            units = _defaultList.units.dup;

        static if (isQuantity!Q)
            units[symbol] = unit.toRuntime;
        else
            units[symbol] = unit;
    }
}

private
{
    enum siRTUnits = [
        "m" : meter.toRuntime,
        "kg" : kilogram.toRuntime,
        "s" : second.toRuntime,
        "A" : ampere.toRuntime,
        "K" : kelvin.toRuntime,
        "mol" : mole.toRuntime,
        "cd" : candela.toRuntime,
        "rad" : radian.toRuntime,
        "sr" : steradian.toRuntime,
        "Hz" : hertz.toRuntime,
        "N" : newton.toRuntime,
        "Pa" : pascal.toRuntime,
        "J" : joule.toRuntime,
        "W" : watt.toRuntime,
        "C" : coulomb.toRuntime,
        "V" : volt.toRuntime,
        "F" : farad.toRuntime,
        "Ω" : ohm.toRuntime,
        "S" : siemens.toRuntime,
        "Wb" : weber.toRuntime,
        "T" : tesla.toRuntime,
        "H" : henry.toRuntime,
        "lm" : lumen.toRuntime,
        "lx" : lux.toRuntime,
        "Bq" : becquerel.toRuntime,
        "Gy" : gray.toRuntime,
        "Sv" : sievert.toRuntime,
        "kat" : katal.toRuntime,
        "g" : gram.toRuntime,
        "min" : minute.toRuntime,
        "h" : hour.toRuntime,
        "d" : day.toRuntime,
        "l" : liter.toRuntime,
        "L" : liter.toRuntime,
        "t" : ton.toRuntime,
        "eV" : electronVolt.toRuntime,
        "Da" : dalton.toRuntime,
    ];
    
    enum siRTPrefixes = [
        "Y" : 1e24L,
        "Z" : 1e21L,
        "E" : 1e18L,
        "P" : 1e15L,
        "T" : 1e12L,
        "G" : 1e9L,
        "M" : 1e6L,
        "k" : 1e3L,
        "h" : 1e2L,
        "da": 1e1L,
        "d" : 1e-1L,
        "c" : 1e-2L,
        "m" : 1e-3L,
        "µ" : 1e-6L,
        "n" : 1e-9L,
        "p" : 1e-12L,
        "f" : 1e-15L,
        "a" : 1e-18L,
        "z" : 1e-21L,
        "y" : 1e-24L,
        "Yi": (2.0^^10)^^8,
        "Zi": (2.0^^10)^^7,
        "Ei": (2.0^^10)^^6,
        "Pi": (2.0^^10)^^5,
        "Ti": (2.0^^10)^^4,
        "Gi": (2.0^^10)^^3,
        "Mi": (2.0^^10)^^2,
        "Ki": (2.0^^10),
    ];
}

/// Exception thrown when parsing encounters an unexpected token.
class ParsingException : Exception
{
    @safe pure nothrow
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @safe pure nothrow
    this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

package:

// Convert a compile-time quantity to its runtime equivalent.
RTQuantity toRuntime(Q)(Q quantity)
    if (isQuantity!Q)
{
    return RTQuantity(quantity.rawValue, toAA!(Q.dimensions));
}

enum Tok
{
    none,
    symbol,
    mul,
    div,
    exp,
    integer,
    supinteger,
    rparen,
    lparen
}

struct Token
{
    Tok type;
    string slice;
    int integer = int.max;
}

enum ctSupIntegerMap = [
    '⁰':'0',
    '¹':'1',
    '²':'2',
    '³':'3',
    '⁴':'4',
    '⁵':'5',
    '⁶':'6',
    '⁷':'7',
    '⁸':'8',
    '⁹':'9',
    '⁺':'+',
    '⁻':'-'
];
static __gshared dchar[dchar] supIntegerMap;
shared static this()
{
    supIntegerMap = ctSupIntegerMap;
}

Token[] lex(string input)
{
    enum State
    {
        none,
        symbol,
        integer,
        supinteger
    }

    Token[] tokens;
    auto original = input;
    size_t i, j;
    State state = State.none;

    void pushToken(Tok type)
    {
        tokens ~= Token(type, original[i .. j]);
        i = j;
        state = State.none;
    }

    void pushInteger(Tok type)
    {
        auto slice = original[i .. j];
        if (type == Tok.supinteger)
        {
            if (__ctfe)
                slice = translate(slice, ctSupIntegerMap);
            else
                slice = translate(slice, supIntegerMap);

        }
        auto n = std.conv.parse!int(slice);
        enforceEx!ParsingException(slice.empty, "Unexpected integer format: " ~ slice);
        tokens ~= Token(type, original[i .. j], n);
        i = j;
        state = State.none;
    }

    void push()
    {
        if (state == State.symbol)
            pushToken(Tok.symbol);
        else if (state == State.integer)
            pushInteger(Tok.integer);
        else if (state == State.supinteger)
            pushInteger(Tok.supinteger);
    }

    while (!input.empty)
    {
        auto cur = input.front;
        auto len = cur.codeLength!char;
        switch (cur)
        {
            case ' ':
            case '\t':
                push();
                j += len;
                i = j;
                break;

            case '(':
                push();
                j += len;
                pushToken(Tok.lparen);
                break;

            case ')':
                push();
                j += len;
                pushToken(Tok.rparen);
                break;

            case '*':
            case '.':
            case '⋅':
            case '×':
                push();
                j += len;
                pushToken(Tok.mul);
                break;

            case '/':
            case '÷':
                push();
                j += len;
                pushToken(Tok.div);
                break;

            case '^':
                push();
                j += len;
                pushToken(Tok.exp);
                break;

            case '0': .. case '9':
            case '-':
            case '+':
                if (state != State.integer)
                    push();
                state = State.integer;
                j += len;
                break;

            case '⁰':
            case '¹':
            case '²':
            case '³':
            case '⁴':
            case '⁵':
            case '⁶':
            case '⁷':
            case '⁸':
            case '⁹':
            case '⁻':
            case '⁺':
                if (state != State.supinteger)
                    push();
                state = State.supinteger;
                j += len;
                break;

            default:
                if (state == State.integer || state == State.supinteger)
                    push();
                state = State.symbol;
                j += len;
                break;
        }
        input.popFront();
    }
    push();
    return tokens;
}

void advance(Types...)(ref Token[] tokens, Types types)
{
    enforceEx!ParsingException(!tokens.empty, "Unexpected end of input");
    tokens.popFront();

    static if (Types.length)
        check(tokens, types);
}

void check(Types...)(Token[] tokens, Types types)
{
    enforceEx!ParsingException(!tokens.empty, "Unexpected end of input");
    auto token = tokens.front;

    static if (Types.length)
    {
        bool ok = false;
        Tok[] valid = [types];
        foreach (type; types)
        {
            if (token.type == type)
            {
                ok = true;
                break;
            }
        }
        import std.string : format;
        enforceEx!ParsingException(ok, valid.length > 1
                                   ? format("Found '%s' while expecting one of [%(%s, %)]", token.slice, valid)
                                   : format("Found '%s' while expecting %s", token.slice, valid.front)
                                   );
    }
}

// Mul or div two dimension arrays
int[string] binop(string op)(int[string] dim1, int[string] dim2)
{
    static assert(op == "*" || op == "/", "Unsupported dimension operator: " ~ op);

    int[string] result;

    // Clone these dimensions in the result
    if (__ctfe)
    {
        foreach (key; dim1.keys)
            result[key] = dim1[key];
    }
    else
        result = dim1.dup;

    // Merge the other dimensions
    foreach (sym, pow; dim2)
    {
        enum powop = op == "*" ? "+" : "-";

        if (sym in dim1)
        {
            // A dimension is common between this one and the other:
            // add or sub them
            auto p = mixin("dim1[sym]" ~ powop ~ "pow");

            // If the power becomes 0, remove the dimension from the list
            // otherwise, set the new power
            if (p == 0)
                result.remove(sym);
            else
                result[sym] = p;
        }
        else
        {
            // Add this new dimensions to the result
            // (with a negative power if op == "/")
            result[sym] = mixin(powop ~ "pow");
        }
    }

    return result;
}

// Raise a dimension array to a integer power (value)
int[string] exp(int[string] dim, int value)
{
    if (value == 0)
        return null;

    int[string] result;
    foreach (sym, pow; dim)
        result[sym] = pow * value;
    return result;
}

// Raise a dimension array to a rational power (1/value)
int[string] expInv(int[string] dim, int value)
{
    assert(value > 0, "Bug: using Dimensions.expInv with a value <= 0");

    int[string] result;
    foreach (sym, pow; dim)
    {
        enforce(pow % value == 0, "Operation results in a non-integral dimension");
        result[sym] = pow / value;
    }
    return result;
}

// Returns the string representation of a dimension array
string dimstr(int[string] dim, bool complete = false)
{
    import std.algorithm : filter;
    import std.array : join;
    import std.conv : to;

    static string stringize(string base, int power)
    {
        if (power == 0)
            return null;
        if (power == 1)
            return base;
        return base ~ "^" ~ to!string(power);
    }

    string[] dimstrs;
    foreach (sym, pow; dim)
        dimstrs ~= stringize(sym, pow);

    string result = dimstrs.filter!"a !is null".join(" ");
    if (!result.length)
        return complete ? "scalar" : "";

    return result;
}
