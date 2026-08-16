local harness = { passed = 0, failed = 0 }

function harness.check(label, condition, detail)
    if condition then
        harness.passed = harness.passed + 1
        print("  ok   " .. label)
    else
        harness.failed = harness.failed + 1
        print("  FAIL " .. label .. (detail and ("  <- " .. tostring(detail)) or ""))
    end
end

function harness.step(label)
    print("\n" .. label)
end

function harness.report()
    print(string.format("\n%d passed, %d failed", harness.passed, harness.failed))

    if harness.failed > 0 then
        os.exit(1)
    end
end

return harness
