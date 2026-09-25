mod util;

fn main() {
    println!("{}", util::greet());
    let again = util::greet();
    println!("{}", again);
}
