/// Tom Assistant server — the product-side consumer of the Tom Brain cognition.
///
/// Exposes [TomBrainClient], the OpenAI-format client that points a Tom
/// Assistant process at a stood-up Tom Brain's `/v1/chat/completions` gateway
/// (`tom_brain_access_specification.md`). This is the seam through which the
/// assistant consumes the brain (quest `tom_brain`, UB6 → OT9).
library;

export 'src/tom_brain_client.dart'
    show
        TomBrainClient,
        TomBrainCompletion,
        TomBrainMessage,
        TomBrainClientException;
