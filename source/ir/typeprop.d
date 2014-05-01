/*****************************************************************************
*
*                      Higgs JavaScript Virtual Machine
*
*  This file is part of the Higgs project. The project is distributed at:
*  https://github.com/maximecb/Higgs
*
*  Copyright (c) 2011-2014, Maxime Chevalier-Boisvert. All rights reserved.
*
*  This software is licensed under the following license (Modified BSD
*  License):
*
*  Redistribution and use in source and binary forms, with or without
*  modification, are permitted provided that the following conditions are
*  met:
*   1. Redistributions of source code must retain the above copyright
*      notice, this list of conditions and the following disclaimer.
*   2. Redistributions in binary form must reproduce the above copyright
*      notice, this list of conditions and the following disclaimer in the
*      documentation and/or other materials provided with the distribution.
*   3. The name of the author may not be used to endorse or promote
*      products derived from this software without specific prior written
*      permission.
*
*  THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED
*  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
*  MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
*  NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
*  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
*  NOT LIMITED TO PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
*  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
*  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
*  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
*  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*
*****************************************************************************/

module ir.typeprop;

import std.stdio;
import std.array;
import std.string;
import std.stdint;
import std.conv;
import ir.ir;
import ir.ops;
import ir.livevars;
import runtime.vm;
import jit.ops;

/// Type test result
enum TestResult
{
    TRUE,
    FALSE,
    UNKNOWN
}

/**
Type analysis results for a given function
*/
class TypeProp
{
    /// Type representation, propagated by the analysis
    private struct TypeSet
    {
        uint32_t bits;

        this(uint32_t bits) { this.bits = bits; }
        this(Type t) { bits = 1 << cast(int)t; }

        /*
        string toString() const
        {
            switch (state)
            {
                case ANY:
                return "bot/unknown";

                case UNINF:
                return "top/uninf";

                case KNOWN_TYPE:
                return to!string(type);

                case KNOWN_BOOL:
                return to!string(val);

                default:
                assert (false);
            }
        }
        */

        /// Check that the type set contains only a given type
        bool isType(Type t) const
        {
            auto bit = 1 << cast(int)t;
            return (this.bits == bit);
        }

        /// Check that the type set does not contain a given type
        bool isNotType(Type t) const
        {
            auto bit = 1 << cast(int)t;
            return (this.bits & bit) == 0;
        }

        /// Check that the type set contains a given type (and maybe others)
        bool maybeIsType(Type t) const
        {
            auto bit = 1 << cast(int)t;
            return (this.bits & bit) != 0;
        }

        /// Check that the type set contains other types than a given type
        bool maybeNotType(Type t) const
        {
            auto bit = 1 << cast(int)t;
            return (this.bits & ~bit) != 0;
        }

        /// Compute the merge (union) with another type value
        TypeSet merge(const TypeSet that) const
        {
            return TypeSet(this.bits | that.bits);
        }

        /// Remove a type from this type set
        TypeSet subtract(Type t) const
        {
            auto bit = 1 << cast(int)t;
            return TypeSet(this.bits & ~bit);
        }
    }

    /// Uninferred type value (top)
    private static const UNINF = TypeSet(0);

    /// Unknown (any type) value (bottom)
    private static const ANY = TypeSet(0xFFFFFFFF);

    /// Map of IR values to type values
    private alias TypeSet[IRDstValue] TypeMap;

    /// Array of type values
    private alias TypeSet[] TypeArr;

    /// Argument type arrays, per instruction
    private TypeArr[IRInstr] instrArgTypes;

    /// Perform an "is_type" type check for an argument of a given instruction
    public TestResult argIsType(IRInstr instr, size_t argIdx, Type type)
    {
        //writeln(instr);

        auto argTypes = instrArgTypes[instr];
        assert (argIdx < argTypes.length);
        auto typeVal = argTypes[argIdx];

        assert (
            typeVal != UNINF,
            format(
                "type uninf for:\n %s in:\n%s",
                instr,
                instr.block.fun
            )
        );

        //writeln("ANY: ", typeVal == ANY);
        //writeln("UNINF: ", typeVal == UNINF);

        if (typeVal.isType(type))
            return TestResult.TRUE;

        if (typeVal.isNotType(type))
            return TestResult.FALSE;

        return TestResult.UNKNOWN;
    }

    /**
    Perform type propagation on an intraprocedural CFG using
    the sparse conditional constant propagation technique
    */
    public this(IRFunction fun, LiveInfo liveInfo)
    {
        //writeln("running type prop on: ", fun.getName);

        // List of CFG edges to be processed
        BranchEdge[] cfgWorkList;

        // Set of reachable blocks
        bool[IRBlock] reachable;

        // Set of visited edges
        bool[BranchEdge] edgeVisited;

        // Map of branch edges to type maps
        TypeMap[BranchEdge] edgeMaps;

        // Add the entry block to the CFG work list
        auto entryEdge = new BranchEdge(null, fun.entryBlock);
        cfgWorkList ~= entryEdge;

        /// Get a type for a given IR value
        auto getType(TypeMap typeMap, IRValue val)
        {
            if (auto dstVal = cast(IRDstValue)val)
                return typeMap.get(dstVal, UNINF);

            if (cast(IRString)val ||
                cast(IRFunPtr)val ||
                cast(IRMapPtr)val ||
                cast(IRLinkIdx)val)
                return ANY;

            // Get the constant value pair for this IR value
            auto cstVal = val.cstValue();

            if (cstVal == TRUE)
                return TypeSet(true);
            if (cstVal == FALSE)
                return TypeSet(false);

            return TypeSet(cstVal.type);
        }

        /// Queue a branch into the work list
        void queueSucc(BranchEdge edge, TypeMap typeMap, IRDstValue branch, TypeSet branchType)
        {
            assert (edge !is null);

            //writeln(branch);
            //writeln("  ", branchType);

            // Flag to indicate the branch type map changed
            bool changed = false;

            // Get the map for this edge
            if (edge !in edgeMaps)
                edgeMaps[edge] = TypeMap.init;
            auto edgeMap = edgeMaps[edge];

            // If a value to be propagated was specified, merge it
            if (branch !is null)
            {
                auto curType = getType(edgeMap, branch);
                auto newType = curType.merge(branchType);
                if (newType != curType)
                {
                    //writeln(branch, " ==> ", newType);

                    edgeMaps[edge][branch] = newType;
                    changed = true;
                }
            }

            // For each type in the incoming map
            foreach (val, inType; typeMap)
            {
                // If this is the value to be propagated,
                // don't propagate the old value
                if (val is branch)
                    continue;

                // Compute the merge of the current and new type
                auto curType = getType(edgeMap, val);
                auto newType = curType.merge(inType);

                // If the type changed, update it
                if (newType != curType)
                {
                    //writeln(val, " ==> ", newType);

                    edgeMaps[edge][val] = newType;
                    changed = true;
                }
            }

            // If the type map changed, queue this edge
            if (changed)
                cfgWorkList ~= edge;
        }

        // Separate function to evaluate phis
        auto evalPhi(PhiNode phi)
        {
            // If this is a function parameter, unknown type
            if (cast(FunParam)phi)
                return ANY;

            TypeSet curType = UNINF;

            // For each incoming branch
            for (size_t i = 0; i < phi.block.numIncoming; ++i)
            {
                auto edge = phi.block.getIncoming(i);

                // If the edge from the predecessor is not reachable, ignore its value
                if (edge !in edgeVisited)
                    continue;

                auto argVal = edge.getPhiArg(phi);
                auto argType = getType(edgeMaps[edge], argVal);

                // If any arg is still unevaluated, the current value is unevaluated
                if (argType == UNINF)
                    return UNINF;

                // Merge the argument type with the current type
                curType = curType.merge(argType);
            }

            // All uses have the same constant type
            return curType;
        }

        /// Evaluate an instruction
        auto evalInstr(IRInstr instr, TypeMap typeMap)
        {
            auto op = instr.opcode;

            // Get the type for argument 0
            auto arg0 = (instr.numArgs > 0)? instr.getArg(0):null;
            auto arg0Type = arg0? getType(typeMap, arg0):UNINF;

            /// Templated implementation of type check operations
            TypeSet IsTypeOp(Type type)()
            {
                // If our only use is an immediately following if_true
                // and the argument type has been inferred
                if (ifUseNext(instr) is true && arg0Type != UNINF)
                {
                    auto ifInstr = instr.next;

                    auto propVal = cast(IRDstValue)arg0;
                    auto trueType = TypeSet(type);
                    auto falseType = arg0Type.subtract(type);

                    // If the argument could be the type we're testing
                    // The true branch knows that the argument is the type tested
                    if (arg0Type.maybeIsType(type))
                        queueSucc(ifInstr.getTarget(0), typeMap, propVal, trueType);

                    // If the argument could be something else than the type we're testing
                    // The false branch knows that the argument is not the type tested
                    if (arg0Type.maybeNotType(type))
                        queueSucc(ifInstr.getTarget(1), typeMap, propVal, falseType);
                }

                return TypeSet(Type.CONST);
            }

            // Get type
            if (op is &GET_TYPE)
            {
                return arg0Type;
            }

            // Get word
            if (op is &GET_WORD)
            {
                return TypeSet(Type.INT64);
            }

            // Make value
            if (op is &MAKE_VALUE)
            {
                // Unknown type, non-constant
                return ANY;
            }

            // Get argume nt (var arg)
            if (op is &GET_ARG)
            {
                // Unknown type, non-constant
                return ANY;
            }

            // Set string
            if (op is &SET_STR)
            {
                return TypeSet(Type.STRING);
            }

            // Get string
            if (op is &GET_STR)
            {
                return TypeSet(Type.STRING);
            }

            // Make link
            if (op is &MAKE_LINK)
            {
                return TypeSet(Type.INT32);
            }

            // Get link value
            if (op is &GET_LINK)
            {
                // Unknown type, value could have any type
                return ANY;
            }

            // Get interpreter objects
            if (op is &GET_GLOBAL_OBJ ||
                op is &GET_OBJ_PROTO ||
                op is &GET_ARR_PROTO ||
                op is &GET_FUN_PROTO)
            {
                return TypeSet(Type.OBJECT);
            }

            // Read global variable
            if (op is &GET_GLOBAL)
            {
                // Unknown type, non-constant
                return ANY;
            }

            // int32 arithmetic/logical
            if (
                op is &ADD_I32 ||
                op is &SUB_I32 ||
                op is &MUL_I32 ||
                op is &DIV_I32 ||
                op is &MOD_I32 ||
                op is &AND_I32 ||
                op is &OR_I32 ||
                op is &XOR_I32 ||
                op is &NOT_I32 ||
                op is &LSFT_I32 ||
                op is &RSFT_I32 ||
                op is &URSFT_I32)
            {
                return TypeSet(Type.INT32);
            }

            // int32 arithmetic with overflow
            if (
                op is &ADD_I32_OVF ||
                op is &SUB_I32_OVF ||
                op is &MUL_I32_OVF)
            {
                auto intType = TypeSet(Type.INT32);

                // Queue both branch targets
                queueSucc(instr.getTarget(0), typeMap, instr, intType);
                queueSucc(instr.getTarget(1), typeMap, instr, intType);

                return intType;
            }

            // float64 arithmetic/trigonometric
            if (
                op is &ADD_F64 ||
                op is &SUB_F64 ||
                op is &MUL_F64 ||
                op is &DIV_F64 ||
                op is &MOD_F64 ||
                op is &SQRT_F64 ||
                op is &SIN_F64  ||
                op is &COS_F64  ||
                op is &LOG_F64  ||
                op is &EXP_F64  ||
                op is &POW_F64  ||
                op is &FLOOR_F64 ||
                op is &CEIL_F64)
            {
                return TypeSet(Type.FLOAT64);
            }

            // int to float
            if (op is &I32_TO_F64)
            {
                return TypeSet(Type.FLOAT64);
            }

            // float to int
            if (op is &F64_TO_I32)
            {
                return TypeSet(Type.INT32);
            }

            // float to string
            if (op is &F64_TO_STR)
            {
                return TypeSet(Type.STRING);
            }

            // Load integer
            if (
                op is &LOAD_U8 ||
                op is &LOAD_U16 ||
                op is &LOAD_U32)
            {
                return TypeSet(Type.INT32);
            }

            // Load 64-bit integer
            if (op is &LOAD_U64)
            {
                return TypeSet(Type.INT64);
            }

            // Load f64
            if (op is &LOAD_F64)
            {
                return TypeSet(Type.FLOAT64);
            }

            // Load refptr
            if (op is &LOAD_REFPTR)
            {
                return TypeSet(Type.REFPTR);
            }

            // Load funptr
            if (op is &LOAD_FUNPTR)
            {
                return TypeSet(Type.FUNPTR);
            }

            // Load mapptr
            if (op is &LOAD_MAPPTR)
            {
                return TypeSet(Type.MAPPTR);
            }

            // Load rawptr
            if (op is &LOAD_RAWPTR)
            {
                return TypeSet(Type.RAWPTR);
            }

            // Heap alloc untyped
            if (op is &ALLOC_REFPTR)
            {
                return TypeSet(Type.REFPTR);
            }

            // Heap alloc string
            if (op is &ALLOC_STRING)
            {
                return TypeSet(Type.STRING);
            }

            // Heap alloc object
            if (op is &ALLOC_OBJECT)
            {
                return TypeSet(Type.OBJECT);
            }

            // Heap alloc array
            if (op is &ALLOC_ARRAY)
            {
                return TypeSet(Type.ARRAY);
            }

            // Heap alloc closure
            if (op is &ALLOC_CLOSURE)
            {
                return TypeSet(Type.CLOSURE);
            }

            // Make map
            if (op is &MAKE_MAP)
            {
                return TypeSet(Type.MAPPTR);
            }

            // Map property count
            if (op is &MAP_NUM_PROPS)
            {
                return TypeSet(Type.INT32);
            }

            // Map property index
            if (op is &MAP_PROP_IDX)
            {
                return TypeSet(Type.INT32);
            }

            // Map property name
            if (op is &MAP_PROP_NAME)
            {
                return TypeSet(Type.STRING);
            }

            // New closure
            if (op is &NEW_CLOS)
            {
                return TypeSet(Type.CLOSURE);
            }

            // Get time in milliseconds
            if (op is &GET_TIME_MS)
            {
                return TypeSet(Type.FLOAT64);
            }

            // Comparison operations
            if (
                op is &EQ_I8 ||
                op is &LT_I32 ||
                op is &LE_I32 ||
                op is &GT_I32 ||
                op is &GE_I32 ||
                op is &EQ_I32 ||
                op is &NE_I32 ||
                op is &LT_F64 ||
                op is &LE_F64 ||
                op is &GT_F64 ||
                op is &GE_F64 ||
                op is &EQ_F64 ||
                op is &NE_F64 ||
                op is &EQ_CONST ||
                op is &NE_CONST ||
                op is &EQ_REFPTR ||
                op is &NE_REFPTR ||
                op is &EQ_RAWPTR ||
                op is &NE_RAWPTR

            )
            {
                // If our only use is an immediately following if_true
                if (ifUseNext(instr) is true)
                {
                    // Queue both branch edges
                    auto ifInstr = instr.next;
                    queueSucc(ifInstr.getTarget(0), typeMap, ifInstr, ANY);
                    queueSucc(ifInstr.getTarget(1), typeMap, ifInstr, ANY);
                }

                // Constant, boolean type
                return TypeSet(Type.CONST);
            }

            // is_i32
            if (op is &IS_I32)
            {
                return IsTypeOp!(Type.INT32)();
            }

            // is_f64
            if (op is &IS_F64)
            {
                return IsTypeOp!(Type.FLOAT64)();
            }

            // is_const
            if (op is &IS_CONST)
            {
                return IsTypeOp!(Type.CONST)();
            }

            // is_refptr
            if (op is &IS_REFPTR)
            {
                return IsTypeOp!(Type.REFPTR)();
            }

            // is_object
            if (op is &IS_OBJECT)
            {
                return IsTypeOp!(Type.OBJECT)();
            }

            // is_array
            if (op is &IS_ARRAY)
            {
                return IsTypeOp!(Type.ARRAY)();
            }

            // is_closure
            if (op is &IS_CLOSURE)
            {
                return IsTypeOp!(Type.CLOSURE)();
            }

            // is_string
            if (op is &IS_STRING)
            {
                return IsTypeOp!(Type.STRING)();
            }

            // is_rawptr
            if (op is &IS_RAWPTR)
            {
                return IsTypeOp!(Type.RAWPTR)();
            }

            // Conditional branch
            if (op is &IF_TRUE)
            {
                // If a boolean argument immediately precedes, the
                // conditional branch has already been handled
                if (boolArgPrev(instr) is true)
                    return ANY;

                // Queue both branch edges
                queueSucc(instr.getTarget(0), typeMap, instr, ANY);
                queueSucc(instr.getTarget(1), typeMap, instr, ANY);

                return ANY;
            }

            // Call instructions
            if (op.isCall)
            {
                // Queue branch edges
                if (instr.getTarget(0))
                    queueSucc(instr.getTarget(0), typeMap, instr, ANY);
                if (instr.getTarget(1))
                    queueSucc(instr.getTarget(1), typeMap, instr, ANY);

                // Unknown, non-constant type
                return ANY;
            }

            // Direct branch
            if (op is &JUMP)
            {
                // Queue the jump branch edge
                queueSucc(instr.getTarget(0), typeMap, instr, ANY);
            }

            // Operations producing no output
            if (op.output is false)
            {
                // Return the unknown type
                return ANY;
            }

            // Ensure that we produce a type for all instructions with an output
            assert (
                false,
                format("unhandled instruction: %s", instr)
            );
        }

        // Until the work list is empty
        while (cfgWorkList.length > 0)
        {
            // Remove an edge from the work list
            auto edge = cfgWorkList[$-1];
            cfgWorkList.length--;
            auto block = edge.target;

            //writeln("iterating ", block.getName);

            // Mark the edge and block as visited
            edgeVisited[edge] = true;
            reachable[block] = true;

            // Type map for the current program point
            TypeMap typeMap;

            // For each incoming branch
            for (size_t i = 0; i < block.numIncoming; ++i)
            {
                auto branch = block.getIncoming(i);

                // If the edge from the predecessor is not reachable, ignore its value
                if (branch !in edgeVisited)
                    continue;

                // Merge live values of the predecessor map
                auto predMap = edgeMaps[branch];
                foreach (val, predType; predMap)
                {
                    if (liveInfo.liveAtEntry(val, block))
                        typeMap[val] = predType.merge(typeMap.get(val, UNINF));
                }
            }

            // For each phi node
            for (auto phi = block.firstPhi; phi !is null; phi = phi.next)
            {
                //writeln("  evaluating phi: ", phi);

                // Re-evaluate the type of the phi node
                typeMap[phi] = evalPhi(phi);
            }

            // For each instruction
            for (auto instr = block.firstInstr; instr !is null; instr = instr.next)
            {
                //writeln("  evaluating instr:", instr);

                // Store the argument types for later querying
                if (instr !in instrArgTypes)
                    instrArgTypes[instr] = new TypeSet[instr.numArgs];
                auto argTypes = instrArgTypes[instr];
                for (size_t i = 0; i < instr.numArgs; ++i)
                    argTypes[i] = getType(typeMap, instr.getArg(i));

                // Re-evaluate the instruction's type
                typeMap[instr] = evalInstr(instr, typeMap);

                //writeln("  instr eval done");
            }
        }

        //writeln("type prop done");
    }
}

