// Written in the D programming language
/++
This module defines functions to parse units and quantities.

Copyright: Copyright 2013, Nicolas Sicard
Authors: Nicolas Sicard
License: $(LINK www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
Source: $(LINK https://github.com/biozic/quantities)
+/
// TODO: Show 'grammar'
module quantities.parsing;

import quantities.base;
import quantities.si;
import quantities._impl;
public import quantities._impl : DimensionException;
import std.conv;
import std.exception;
import std.range;
import std.string;
import std.traits;
import std.utf;

// TODO: Parse an ForwardRange of Char: stop at position where there is a parsing error and go back to last known good position
// TODO: Parse space between two units as a multiplication mark
// TODO: Add possibility to add user-defined units in the parser
// TODO: Add conversion functions from parsed quantities and units.

version (Have_tested) import tested;
else private struct name { string dummy; }

version (unittest)
    import std.math : approxEqual;

/// Parses the text for a quantity (with a numerical value) at runtime.
auto parseQuantity(alias Q, N = double, S)(S text)
    if (isSomeString!S)
{
    RTQuantity quant = parseRTQuantity(text);
    quant.checkDim(Q.dimensions);
    return Quantity!(Q.dimensions, N)(quant.rawValue);
}
///
@name("Parsing quantities")
unittest
{
    alias Concentration = Store!(mole/cubic!meter);
    
    // Parse a concentration value
    auto c = parseQuantity!Concentration("11.2 µmol/L");
    assert(approxEqual(c.value(nano!mole/liter), 11200));
    
    // Below, 'second' is only a hint for dimensional analysis
    auto t = parseQuantity!second("1 min");
    assert(t == 1 * minute);
}

/// Parses the text for a quantity (with a numerical value) at runtime.
auto parseUnit(alias Q, N = double, S)(S text)
    if (isSomeString!S)
{
    return parseQuantity!(Q, N)("1" ~ text);
}
///
@name("Parsing units")
unittest
{
    alias Concentration = Store!(mole/cubic!meter);

    // Parse a concentration value
    auto c = parseQuantity!Concentration("11.2 µmol/L"d);

    // Parse a unit
    auto u = parseUnit!Concentration("mol/cm³");

    // Convert
    assert(approxEqual(c.value(u), 1.12e-8));
}

/++
Convert a quantity parsed from a string into target unit, also parsed from
a string.
Parameters:
  from = A string representing the quantity to convert
  target = A string representing the target unit
Returns:
    The conversion factor (a scalar value)
+/
real convert(S, U)(S from, U target)
    if (isSomeString!S && isSomeString!U)
{
    RTQuantity base = parseRTQuantity(from);
    RTQuantity unit = parseRTQuantity("1" ~ target);
    return base.value(unit);
}
///
@name("Convert")
unittest
{
    auto k = convert("3 min", "s");
    assert(k == 180);
}

/// Exception thrown when parsing encounters an unexpected token.
class ParseException : Exception
{
    @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }
    
    @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

package:

//debug import std.stdio;

RTQuantity parseRTQuantity(S)(S text)
    if (isSomeString!S)
{
    auto value = std.conv.parse!real(text);
    if (!text.length)
        return RTQuantity(Dimensions.init, value);
    auto tokens = lex(text);
    //debug writeln(tokens);
    return value * parseCompoundUnit(tokens);
}

@name("Parsing a quantity into RTQuantity")
unittest
{
    import std.math : approxEqual;

    assertThrown!ParseException(parseRTQuantity("1 µ m"));
    assertThrown!ParseException(parseRTQuantity("1 µ"));

    string test = "1    m    ";
    assert(parseRTQuantity(test) == RT.meter);
    assert(parseRTQuantity("1 µm") == 1e-6 * RT.meter);

    assert(parseRTQuantity("1 m^-1") == 1 / RT.meter);
    assert(parseRTQuantity("1 m²") == square(RT.meter));
    assert(parseRTQuantity("1 m⁻¹") == 1 / RT.meter);
    assert(parseRTQuantity("1 (m)") == RT.meter);
    assert(parseRTQuantity("1 (m^-1)") == 1 / RT.meter);
    assert(parseRTQuantity("1 ((m)^-1)^-1") == RT.meter);

    assert(parseRTQuantity("1 m * m") == square(RT.meter));
    assert(parseRTQuantity("1 m . m") == square(RT.meter));
    assert(parseRTQuantity("1 m ⋅ m") == square(RT.meter));
    assert(parseRTQuantity("1 m × m") == square(RT.meter));
    assert(parseRTQuantity("1 m / m") == RT.meter / RT.meter);
    assert(parseRTQuantity("1 m ÷ m") == RT.meter / RT.meter);

    assert(parseRTQuantity("1 N.m") == RT.newton * RT.meter);
    // assert(parseRTQuantity("1 N m") == RT.newton * RT.meter);
    
    assert(approxEqual(parseRTQuantity("6.3 L.mmol^-1.cm^-1").value(square(RT.meter)/RT.mole), 630));
    assert(approxEqual(parseRTQuantity("6.3 L/(mmol*cm)").value(square(RT.meter)/RT.mole), 630));
    assert(approxEqual(parseRTQuantity("6.3 L*(mmol*cm)^-1").value(square(RT.meter)/RT.mole), 630));
    assert(approxEqual(parseRTQuantity("6.3 L/mmol/cm").value(square(RT.meter)/RT.mole), 630));
}

package:

void advance(ref Token[] tokens)
{
    enforceEx!ParseException(tokens.length, "Unexpected end of input");
    tokens.popFront();
}

bool check(Types...)(Token token, Types types)
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
    enforceEx!ParseException(ok, valid.length > 1 
        ? format("Found '%s' while expecting one of [%(%s, %)]", token.slice, valid)
        : format("Found '%s' while expecting %s", token.slice, valid.front)
    );
    return ok;
}

RTQuantity parseCompoundUnit(ref Token[] tokens)
{
    //debug writeln(__FUNCTION__);

    RTQuantity ret = parseExponentUnit(tokens);
    while (tokens.length)
    {
        auto op = tokens.front;
        if (op.type != Tok.mul && op.type != Tok.div)
            break;

        tokens.advance();
        RTQuantity rhs = parseExponentUnit(tokens);
        if (op.type == Tok.mul)
            ret.resetTo(ret * rhs);
        else if (op.type == Tok.div)
            ret.resetTo(ret / rhs);
    }
    return ret;
}

RTQuantity parseExponentUnit(ref Token[] tokens)
{
    //debug writeln(__FUNCTION__);

    RTQuantity ret = parseUnit(tokens);
    if (tokens.length && (tokens.front.type == Tok.exp
                          || tokens.front.type == Tok.supinteger))
    {
        if (tokens.front.type == Tok.exp)
            tokens.advance();
        int n = parseInteger(tokens);
        ret.resetTo(pow(ret, n));
    }
    return ret;
}

int parseInteger(ref Token[] tokens)
{
    //debug writeln(__FUNCTION__);

    auto i = tokens.front;
    i.check(Tok.integer, Tok.supinteger);
    auto slice = i.slice;
    if (i.type == Tok.supinteger)
    {
        slice = translate(slice, [
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
        ]);
    }
    auto n = std.conv.parse!int(slice);
    if (tokens.length)
        tokens.advance();
    return n;
}

RTQuantity parseUnit(ref Token[] tokens)
{
    //debug writeln(__FUNCTION__);

    RTQuantity ret;
    
    if (tokens.front.type == Tok.lparen)
    {
        tokens.advance();
        ret = parseCompoundUnit(tokens);
        tokens.front.check(Tok.rparen);
        tokens.advance();
    }
    else
        ret = parsePrefixUnit(tokens);

    return ret;
}

RTQuantity parsePrefixUnit(ref Token[] tokens)
{
    // debug writeln(__FUNCTION__);

    RTQuantity ret;

    tokens.front.check(Tok.symbol);
    auto str = tokens.front.slice;
    if (tokens.length)
        tokens.advance();
    
    // Special cases where a prefix starts like a unit
    if (str == "m")
        return RT.meter;
    if (str == "cd")
        return RT.candela;
    if (str == "mol")
        return RT.mole;
    if (str == "Pa")
        return RT.pascal;
    if (str == "T")
        return RT.tesla;
    if (str == "Gy")
        return RT.gray;
    if (str == "kat")
        return RT.katal;
    if (str == "h")
        return RT.hour;
    if (str == "d")
        return RT.day;
    if (str == "min")
        return RT.minute;
    
    string prefix = str.takeExactly(1).to!string;
    assert(prefix.length, "Prefix with no length");
    auto factor = prefix in RT.SIPrefixSymbols;
    if (factor)
    {
        string unit = str.dropOne.to!string;
        enforceEx!ParseException(unit.length, "Expecting a unit after the prefix " ~ prefix);
        return *factor * parseSymbol(unit);
    }
    else
        return parseSymbol(str);
}

RTQuantity parseSymbol(string str)
{
    assert(str.length, "Symbol with no length");
    return *enforceEx!ParseException(str in RT.SIUnitSymbols, "Unknown unit symbol: " ~ str);
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
}

Token[] lex(S)(S input)
    if (isSomeString!S)
{
    alias C = Unqual!(ElementEncodingType!S);

    enum State
    {
        none,
        symbol,
        integer,
        supinteger
    }
    
    auto original = input;
    Token[] tokapp;
    size_t i, j;
    State state = State.none;
    
    void pushToken(Tok type)
    {
        tokapp ~= Token(type, original[i .. j].to!string);
        i = j;
        state = State.none;
    }
    
    void push()
    {
        if (state == State.symbol)
            pushToken(Tok.symbol);
        else if (state == State.integer)
            pushToken(Tok.integer);
        else if (state == State.supinteger)
            pushToken(Tok.supinteger);
    }
    
    while (!input.empty)
    {
        auto cur = input.front;
        auto len = cur.codeLength!C;
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
    return tokapp;
}