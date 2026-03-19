# Steering Behavior: Kaisha vs Pi-mono

## The difference

**Pi-mono:** Steering messages are delivered AFTER the current tool calls finish executing. The agent completes its planned actions, then receives the steering message for the next turn.

**Kaisha:** Steering messages DISCARD pending tool calls. The agent does NOT execute tools that were planned before the steer. Instead, it re-asks the LLM with the steering context injected.

## Why we diverge

Pi-mono's approach:
- Tool calls were already planned by the LLM
- Let them finish, then steer on the next iteration
- Safer in the sense that partial tool execution doesn't happen
- But: the agent takes actions the user was trying to prevent

Kaisha's approach:
- Steering means "change direction" — the user is correcting course
- Tool calls generated BEFORE the steer are pre-steer decisions
- Executing them defeats the purpose of steering
- Discard them, inject the steer, let the LLM re-decide with new context
- Trade-off: if the LLM had already started a multi-tool sequence, discarding mid-sequence could leave state inconsistent (e.g. file half-written). This is acceptable because the user explicitly asked to redirect.

## Pi-mono reference

The steering behavior is in `packages/agent/src/agent-loop.ts` (~616 lines).

Pi-mono's `getSteeringMessages` callback is called after tool execution completes:
- File: https://github.com/badlogic/pi-mono/blob/main/packages/agent/src/agent-loop.ts
- The `AgentLoopConfig.getSteeringMessages` is documented in types.ts as: "Called after the current assistant turn finishes executing its tool calls. If messages are returned, they are added to the context before the next LLM call. Tool calls from the current assistant message are not skipped."
- Types: https://github.com/badlogic/pi-mono/blob/main/packages/agent/src/types.ts

The key quote from pi-mono types.ts:
> "Tool calls from the current assistant message are not skipped."

We explicitly chose the opposite: tool calls ARE skipped when steering arrives.

## Implementation

Kaisha's steering logic is in `packages/agent-core/src/loop.zig`, in the `send()` method:

```
if (response.tool_calls.len > 0) {
    if (self.steering_queue.items.len > 0) {
        // Discard tool calls — they were planned before the steer
        // Inject steering messages
        // Re-ask LLM with new context
    }
    // else: execute tools normally
}
```

## When this could be wrong

If the LLM issued tool calls that are SAFE and the steering message is additive (not a redirect), discarding them wastes a turn. The LLM will likely re-issue the same calls after seeing the steering message.

A more nuanced approach would let the steering message declare intent:
- `steer("also do X")` → execute tools + add steering (pi-mono behavior)
- `steer("stop, do Y instead")` → discard tools + add steering (kaisha behavior)

For now we default to the stricter behavior (discard). Can be made configurable later.
