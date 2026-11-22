"""A RED succeeds only at its single expected assertion and exit status."""


def require_exact_failure(result, expected, label):
    failures = [line for output in (result.stdout, result.stderr)
                for line in output.splitlines() if line.startswith('FAIL:')]
    if result.returncode != 1 or failures != [expected]:
        raise RuntimeError(label + ' did not reach its unique assertion:\n' + result.stdout + result.stderr)
