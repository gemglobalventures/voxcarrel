import VoxCarrelUI

// The app as it is by itself: nothing is added to it. A program starts on the main
// thread, which is where the app must be started from.
MainActor.assumeIsolated {
    VoxCarrelMain.run()
}
